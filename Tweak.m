/**
 * MAXMods v4.4 — native menu preserved; action handlers deferred past the
 * context-menu dismissal animation to break the freeze deadlock.
 *
 * Confirmed diagnosis (baseline v4.3 test): with the stock system menu,
 * tapping Удалить freezes the app — the app's action handler mutates the
 * collection view / presents a confirmation alert while UIContextMenu's
 * dismissal transition is still running, which deadlocks the main thread on
 * iOS 26/27 with this old-SDK binary. With the custom overlay (v4.2) the same
 * handlers fired with no dismissal in flight — no freeze, proving the
 * handlers themselves are fine and only the timing is fatal.
 *
 * Fix: capture the app's actionProvider + previewProvider (via the
 * +[UIContextMenuConfiguration configurationWith...:] hook), rebuild the
 * identical native menu, but wrap every UIAction handler in a 0.75s
 * dispatch_after — by then the dismissal transition has finished. The menu
 * looks and behaves 100% native; only the handler timing changes.
 * The app itself uses this exact pattern elsewhere (OMContextMenu
 * convertItem:sender:applyActionDelay: with a 300 ms constant).
 *
 * File logging + main-thread watchdog retained from v4.2.
 *
 * Fallback: if any step fails (no provider, unsupported menu elements,
 * exception) we return the original configuration untouched.
 *
 * Session persistence fixes (keychain / app-group / defaults suite) carried
 * over from v3.0 — required after re-signing with a different team id.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================================
#pragma mark - Swizzle helpers
// ============================================================================

static IMP swizzle(Class cls, SEL sel, IMP newImp) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NULL;
    IMP orig = method_getImplementation(method);
    method_setImplementation(method, newImp);
    return orig;
}

static IMP swizzleClassMethod(Class cls, SEL sel, IMP newImp) {
    Method method = class_getClassMethod(cls, sel);
    if (!method) return NULL;
    IMP orig = method_getImplementation(method);
    method_setImplementation(method, newImp);
    return orig;
}

// ============================================================================
#pragma mark - File logging (survives a frozen/killed app) + main-thread watchdog
//
// Everything important is appended to Documents/maxmods_log.txt immediately
// (NSFileHandle writes are unbuffered). The app container is exposed in the
// Files app via UIFileSharingEnabled (patched into Info.plist at repack time),
// so the log can be shared straight from the device even when the app hangs.
// ============================================================================

static NSString *max_logPath(void) {
    static NSString *path;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        path = [docs stringByAppendingPathComponent:@"maxmods_log.txt"];
    });
    return path;
}

static void maxlog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"[MAXMods] %@", msg);

    NSString *path = max_logPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path])
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // cap the file so a stuck logging loop can't grow it unbounded
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if ([attrs fileSize] > 2 * 1024 * 1024)
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

// Every 5s check that the main thread services its queue within 2s.
// A frozen app keeps logging "MAIN THREAD STUCK" lines with timestamps —
// the last lines before the hang pinpoint where it stopped.
static void max_scheduleWatchdog(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{ dispatch_semaphore_signal(sem); });
        if (dispatch_semaphore_wait(sem,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC))) != 0) {
            maxlog(@"WATCHDOG: MAIN THREAD STUCK >2s — app frozen");
        }
        max_scheduleWatchdog();
    });
}

// ============================================================================
#pragma mark - Menu interception state
// ============================================================================

typedef UIMenu *_Nullable (^ActionProviderBlock)(NSArray<UIMenuElement *> *_Nonnull);
typedef UIViewController *_Nullable (^PreviewProviderBlock)(void);

static BOOL g_inMessageCellMenu = NO;   // set while orig cell config runs
static ActionProviderBlock g_capturedProvider = nil;
static PreviewProviderBlock g_capturedPreview = nil;
static id g_capturedIdentifier = nil;
static BOOL g_foundUnsupportedElement = NO;

// How long to defer tapped menu actions so the system menu's dismissal
// transition is fully over before the app's handler runs. The app's own
// analogous delay is 300 ms; dismissal animations can take longer, so be safe.
static NSTimeInterval const kMaxModsActionDelay = 0.75;

// ============================================================================
#pragma mark - Hook: +[UIContextMenuConfiguration configurationWith...]
// ============================================================================

static IMP orig_configCreate = NULL;

static id hook_configCreate(id self, SEL _cmd,
                            id identifier, id previewProvider, id actionProvider) {
    if (g_inMessageCellMenu && actionProvider != nil) {
        g_capturedProvider = [actionProvider copy];
        g_capturedPreview = [previewProvider copy];
        g_capturedIdentifier = identifier;
        maxlog(@"menu: actionProvider captured");
    }
    return ((id(*)(id,SEL,id,id,id))orig_configCreate)(
        self, _cmd, identifier, previewProvider, actionProvider);
}

// ============================================================================
#pragma mark - Deferred-action menu rebuilding
// ============================================================================

// Hidden control used to fire a captured UIAction's handler — the documented
// way to invoke an action outside of a real control event.
static UIControl *max_ghostControl(void) {
    static UIControl *ghost = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ ghost = [UIControl new]; });
    return ghost;
}

// Wrap a UIAction's handler in a dispatch_after so it runs after the system
// menu has fully dismissed. Same title/image/identifier — the menu looks and
// animates 100% native; only the handler timing changes.
// The block strongly retains the original action (the replacement config does
// not keep the original one alive).
static UIAction *max_wrappedAction(UIAction *action) {
    return [UIAction actionWithTitle:action.title
                               image:action.image
                          identifier:action.identifier
                             handler:^(__kindof UIAction *_) {
        (void)_;
        maxlog(@"action fired (deferring %.2fs): %@",
               kMaxModsActionDelay, action.title ?: @"?");
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(kMaxModsActionDelay * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            maxlog(@"action running: %@", action.title ?: @"?");
            UIControl *ghost = max_ghostControl();
            [ghost removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
            [ghost addAction:action forControlEvents:UIControlEventPrimaryActionTriggered];
            [ghost sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
            maxlog(@"action done: %@", action.title ?: @"?");
        });
    }];
}

// Rebuild a UIMenu tree with every UIAction handler deferred.
// Returns nil if the tree contains elements we can't rebuild (deferred
// elements, commands) — caller then falls back to the original config.
static UIMenuElement *max_wrappedElement(UIMenuElement *element) {
    if ([element isKindOfClass:[UIAction class]]) {
        UIAction *a = (UIAction *)element;
        if (a.title.length == 0) return nil;   // separators/unknowns — bail
        return max_wrappedAction(a);
    }
    if ([element isKindOfClass:[UIMenu class]]) {
        UIMenu *menu = (UIMenu *)element;
        NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
        for (UIMenuElement *child in menu.children) {
            UIMenuElement *wrapped = max_wrappedElement(child);
            if (!wrapped) return nil;
            [children addObject:wrapped];
        }
        return [UIMenu menuWithTitle:menu.title
                             image:menu.image
                        identifier:menu.identifier
                           options:menu.options
                          children:children];
    }
    return nil;   // UIDeferredMenuElement / UICommand / ... — not rebuildable
}

// Build a replacement configuration: same identifier and preview as the app's
// own, but every action handler deferred past menu dismissal.
// Returns nil when the menu can't be safely rebuilt.
static UIContextMenuConfiguration *max_deferredConfig(UIContextMenuConfiguration *fallback) {
    if (!g_capturedProvider) return nil;

    UIMenu *menu = nil;
    @try {
        menu = g_capturedProvider(@[]);
    } @catch (NSException *e) {
        maxlog(@"menu: actionProvider threw: %@", e);
        return nil;
    }
    if (!menu) return nil;

    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    for (UIMenuElement *element in menu.children) {
        UIMenuElement *wrapped = max_wrappedElement(element);
        if (!wrapped) {
            maxlog(@"menu: not rebuildable (%@) — system fallback",
                   NSStringFromClass([element class]));
            return nil;
        }
        [children addObject:wrapped];
    }
    if (children.count == 0) return nil;

    UIContextMenuConfiguration *cfg =
        [UIContextMenuConfiguration
            configurationWithIdentifier:g_capturedIdentifier
                          previewProvider:g_capturedPreview
                           actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
                (void)suggested;
                return [UIMenu menuWithChildren:children];
            }];
    maxlog(@"menu: rebuilt native menu with deferred handlers (%lu items)",
           (unsigned long)children.count);
    return cfg;
}

// ============================================================================
#pragma mark - Hook: -[MessageCell contextMenuInteraction:configurationForMenuAtLocation:]
// ============================================================================

static IMP orig_cellConfig = NULL;

static UIContextMenuConfiguration *hook_cellConfig(
        id self, SEL _cmd, UIContextMenuInteraction *interaction, CGPoint point) {

    maxlog(@"menu: entry (MessageCell path)");
    g_capturedProvider = nil;
    g_capturedPreview = nil;
    g_capturedIdentifier = nil;
    g_foundUnsupportedElement = NO;
    g_inMessageCellMenu = YES;
    UIContextMenuConfiguration *config =
        ((UIContextMenuConfiguration *(*)(id,SEL,id,CGPoint))orig_cellConfig)(
            self, _cmd, interaction, point);
    g_inMessageCellMenu = NO;

    UIContextMenuConfiguration *deferred = max_deferredConfig(config);
    return deferred ?: config;
}

// ============================================================================
#pragma mark - Hook: -[ChatDetailController collectionView:contextMenuConfigurationForItemAtIndexPath:point:]
//
// The chat screen builds its message menu through the collection-view delegate
// (ChatDetailController), NOT through MessageCell's per-cell interaction —
// this is the path that actually runs in chats, so it must be intercepted too.
// ============================================================================

static IMP orig_cvConfig = NULL;

static UIContextMenuConfiguration *hook_cvConfig(
        id self, SEL _cmd, UICollectionView *collectionView,
        NSIndexPath *indexPath, CGPoint point) {

    maxlog(@"menu: entry (ChatDetail path)");
    g_capturedProvider = nil;
    g_capturedPreview = nil;
    g_capturedIdentifier = nil;
    g_foundUnsupportedElement = NO;
    g_inMessageCellMenu = YES;
    UIContextMenuConfiguration *config =
        ((UIContextMenuConfiguration *(*)(id,SEL,id,id,CGPoint))orig_cvConfig)(
            self, _cmd, collectionView, indexPath, point);
    g_inMessageCellMenu = NO;

    UIContextMenuConfiguration *deferred = max_deferredConfig(config);
    return deferred ?: config;
}

// ============================================================================
#pragma mark - Session Fix: Keychain (selective)
// ============================================================================

static NSString *const kOrigTeam = @"6T4347P359";
static IMP orig_kcClass = NULL;
static IMP orig_kcInit = NULL;

static id hook_kcClass(id self, SEL _cmd, id service, NSString *group) {
    if (group && [group containsString:kOrigTeam]) {
        return ((id(*)(id,SEL,id,id))orig_kcClass)(self, _cmd, service, nil);
    }
    return ((id(*)(id,SEL,id,id))orig_kcClass)(self, _cmd, service, group);
}

static id hook_kcInit(id self, SEL _cmd, id service, NSString *group) {
    if (group && [group containsString:kOrigTeam]) {
        return ((id(*)(id,SEL,id,id))orig_kcInit)(self, _cmd, service, nil);
    }
    return ((id(*)(id,SEL,id,id))orig_kcInit)(self, _cmd, service, group);
}

// ============================================================================
#pragma mark - Session Fix: App Group Container
// ============================================================================

static IMP orig_containerURL = NULL;

static NSURL *hook_containerURL(id self, SEL _cmd, NSString *groupId) {
    if ([groupId isEqualToString:@"group.ru.oneme.app"] ||
        [groupId hasPrefix:@"6T4347P359."]) {
        NSString *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *fake = [docs stringByAppendingPathComponent:
            [NSString stringWithFormat:@"FakeGroupContainers/%@", groupId]];
        [[NSFileManager defaultManager] createDirectoryAtPath:fake
            withIntermediateDirectories:YES attributes:nil error:nil];
        return [NSURL fileURLWithPath:fake];
    }
    return ((NSURL*(*)(id,SEL,NSString*))orig_containerURL)(self, _cmd, groupId);
}

// ============================================================================
#pragma mark - Session Fix: NSUserDefaults Suite
// ============================================================================

static IMP orig_initSuite = NULL;

static id hook_initSuite(id self, SEL _cmd, NSString *name) {
    if (name && [name isEqualToString:@"group.ru.oneme.app"]) {
        return ((id(*)(id,SEL,NSString*))orig_initSuite)(self, _cmd, @"ru.oneme.app.local");
    }
    return ((id(*)(id,SEL,NSString*))orig_initSuite)(self, _cmd, name);
}

// ============================================================================
#pragma mark - Constructor
// ============================================================================

__attribute__((constructor))
static void maxmods_init(void) {
    maxlog(@"v4.4 loading (native menu + deferred action handlers)...");

    // 1) Capture the app's menu providers for message-cell menus.
    orig_configCreate = swizzleClassMethod([UIContextMenuConfiguration class],
        @selector(configurationWithIdentifier:previewProvider:actionProvider:),
        (IMP)hook_configCreate);
    maxlog(@"UIContextMenuConfiguration hook: %@",
           orig_configCreate ? @"OK" : @"MISS");

    // 2) Replace the system context menu on chat message cells — two entry
    //    points: the per-cell interaction (MessageCell) and the collection-view
    //    delegate (ChatDetailController), which is the one actually used in chats.
    Class messageCell = objc_getClass("_TtC13ChatHistoryUI11MessageCell");
    if (messageCell) {
        orig_cellConfig = swizzle(messageCell,
            @selector(contextMenuInteraction:configurationForMenuAtLocation:),
            (IMP)hook_cellConfig);
        maxlog(@"MessageCell menu hook: %@",
               orig_cellConfig ? @"OK" : @"MISS");
    } else {
        maxlog(@"WARNING: MessageCell class not found");
    }

    Class chatDetail = objc_getClass("_TtC14OMChatDetailUI20ChatDetailController");
    if (chatDetail) {
        orig_cvConfig = swizzle(chatDetail,
            @selector(collectionView:contextMenuConfigurationForItemAtIndexPath:point:),
            (IMP)hook_cvConfig);
        maxlog(@"ChatDetailController menu hook: %@",
               orig_cvConfig ? @"OK" : @"MISS");
    } else {
        maxlog(@"WARNING: ChatDetailController class not found");
    }

    // 3) Session persistence fixes (unchanged from v3.0).
    Class kc = objc_getClass("UICKeyChainStore");
    if (kc) {
        Method cm = class_getClassMethod(kc, @selector(keyChainStoreWithService:accessGroup:));
        if (cm) {
            orig_kcClass = method_getImplementation(cm);
            method_setImplementation(cm, (IMP)hook_kcClass);
        }
        Method im = class_getInstanceMethod(kc, @selector(initWithService:accessGroup:));
        if (im) {
            orig_kcInit = method_getImplementation(im);
            method_setImplementation(im, (IMP)hook_kcInit);
        }
        maxlog(@"Keychain fix: OK");
    }

    orig_containerURL = swizzle([NSFileManager class],
        @selector(containerURLForSecurityApplicationGroupIdentifier:),
        (IMP)hook_containerURL);

    orig_initSuite = swizzle([NSUserDefaults class],
        @selector(initWithSuiteName:), (IMP)hook_initSuite);

    max_scheduleWatchdog();

    maxlog(@"v4.4 loaded OK — log file: %@", max_logPath());
}

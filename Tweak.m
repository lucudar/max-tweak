/**
 * MAXMods v5.0 — Telegram-style custom context menu for chat messages
 * + file logging (Documents/maxmods_log.txt, visible in the Files app)
 * + main-thread watchdog that records freezes into the same log
 *
 * Final diagnosis (v4.3/v4.4/v4.5 baseline tests): the STOCK system menu
 * deadlocks during its own PRESENTATION (before any action tap, watchdog
 * silent) on iOS 26/27 with this old-SDK binary — with or without preview,
 * with or without deferred handlers. The system menu cannot be used at all.
 * The custom overlay (v4.2) ran the same app handlers freeze-free, proving
 * only the UIContextMenuInteraction machinery is broken.
 *
 * Root cause of the delete freeze (long-press -> Удалить -> app hangs):
 *  - MessageCell (Swift, ChatHistoryUI) hosts a per-cell UIContextMenuInteraction
 *    (MessageCell+ContextMenuInteraction.swift).
 *  - The app binary targets an old SDK; on iOS 26/27 the system context-menu
 *    dismissal racing with the collection-view update (message removed) deadlocks
 *    the main thread. The app's own 300 ms action delay (OMContextMenu
 *    convertItem:sender:applyActionDelay:) is not enough on the new iOS.
 *
 * Fix — replace the system menu for message cells with our own overlay:
 *  1. hook -[MessageCell contextMenuInteraction:configurationForMenuAtLocation:]
 *     and call the original (which captures the app's actionProvider block via
 *     the hooked +[UIContextMenuConfiguration configurationWith...:] below);
 *  2. invoke the app's actionProvider ourselves -> UIMenu -> UIActions;
 *  3. present our own Telegram-style overlay panel (blur, icons, haptics,
 *     lifted message snapshot);
 *  4. return nil so iOS never starts a system context menu at all — the
 *     deadlock path (dismissal transition + collection mutation) is gone
 *     by construction;
 *  5. item taps fire the app's own UIAction handlers, so delete/edit/reply/
 *     pin/forward and their confirmation alerts keep working untouched.
 *
 * Fallback: if any step of the interception fails (no provider, empty menu,
 * deferred menu elements, exception, no window) we return the original
 * configuration and the stock system menu is shown exactly as before.
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
#pragma mark - Telegram-style menu overlay (interface)
// ============================================================================

@interface MAXMenuOverlay : UIView
+ (BOOL)isShowing;
+ (BOOL)shouldSkip;
+ (BOOL)presentWithActions:(NSArray<UIAction *> *)actions cell:(UIView *)cell;
@end

// ============================================================================
#pragma mark - Menu interception state
// ============================================================================

typedef UIMenu *_Nullable (^ActionProviderBlock)(NSArray<UIMenuElement *> *_Nonnull);

static BOOL g_inMessageCellMenu = NO;   // set while orig cell config runs
static ActionProviderBlock g_capturedProvider = nil;
static BOOL g_foundUnsupportedElement = NO;

// ============================================================================
#pragma mark - Hook: +[UIContextMenuConfiguration configurationWith...]
// ============================================================================

static IMP orig_configCreate = NULL;

static id hook_configCreate(id self, SEL _cmd,
                            id identifier, id previewProvider, id actionProvider) {
    if (g_inMessageCellMenu && actionProvider != nil) {
        g_capturedProvider = [actionProvider copy];
        maxlog(@"menu: actionProvider captured");
    }
    return ((id(*)(id,SEL,id,id,id))orig_configCreate)(
        self, _cmd, identifier, previewProvider, actionProvider);
}

// ============================================================================
#pragma mark - Menu flattening
// ============================================================================

// Recursively flatten a UIMenu tree into UIActions.
// Anything we can't fire ourselves (UIDeferredMenuElement, UICommand, ...)
// sets the unsupported flag so the caller falls back to the system menu.
static void flattenMenu(UIMenuElement *element, NSMutableArray<UIAction *> *out) {
    if ([element isKindOfClass:[UIAction class]]) {
        [out addObject:(UIAction *)element];
        return;
    }
    if ([element isKindOfClass:[UIMenu class]]) {
        for (UIMenuElement *child in ((UIMenu *)element).children)
            flattenMenu(child, out);
        return;
    }
    maxlog(@"menu: unsupported element %@ — will fall back", NSStringFromClass([element class]));
    g_foundUnsupportedElement = YES;
}

// ============================================================================
#pragma mark - Hook: -[MessageCell contextMenuInteraction:configurationForMenuAtLocation:]
// ============================================================================

static IMP orig_cellConfig = NULL;

static UIContextMenuConfiguration *hook_cellConfig(
        id self, SEL _cmd, UIContextMenuInteraction *interaction, CGPoint point) {

    maxlog(@"menu: entry (MessageCell path)");
    g_capturedProvider = nil;
    g_foundUnsupportedElement = NO;
    g_inMessageCellMenu = YES;
    UIContextMenuConfiguration *config =
        ((UIContextMenuConfiguration *(*)(id,SEL,id,CGPoint))orig_cellConfig)(
            self, _cmd, interaction, point);
    g_inMessageCellMenu = NO;

    if (!g_capturedProvider) {
        maxlog(@"menu: no provider captured — system fallback");
        return config;   // preview-only menu — keep system behavior
    }

    // If a live overlay is still up (double delegate call for the same
    // long-press), keep suppressing; a dismissing one is swapped below.
    if ([MAXMenuOverlay shouldSkip]) return nil;

    UIMenu *menu = nil;
    @try {
        menu = g_capturedProvider(@[]);
    } @catch (NSException *e) {
        maxlog(@"menu: actionProvider threw: %@", e);
        return config;
    }
    g_capturedProvider = nil;

    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (UIMenuElement *element in menu.children)
        flattenMenu(element, actions);

    if (g_foundUnsupportedElement || actions.count == 0) {
        maxlog(@"menu: not interceptable (deferred/empty, %lu actions) — system fallback",
               (unsigned long)actions.count);
        return config;
    }

    if (![MAXMenuOverlay presentWithActions:actions cell:(UIView *)self]) {
        maxlog(@"menu: overlay present failed — system fallback");
        return config;
    }

    return nil;   // no system context menu — no dismissal transition, no deadlock
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
    g_foundUnsupportedElement = NO;
    g_inMessageCellMenu = YES;
    UIContextMenuConfiguration *config =
        ((UIContextMenuConfiguration *(*)(id,SEL,id,id,CGPoint))orig_cvConfig)(
            self, _cmd, collectionView, indexPath, point);
    g_inMessageCellMenu = NO;

    if (!g_capturedProvider) {
        maxlog(@"menu: cv path — no provider captured — system fallback");
        return config;
    }

    if ([MAXMenuOverlay shouldSkip]) return nil;

    UIMenu *menu = nil;
    @try {
        menu = g_capturedProvider(@[]);
    } @catch (NSException *e) {
        maxlog(@"menu: cv actionProvider threw: %@", e);
        return config;
    }
    g_capturedProvider = nil;

    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (UIMenuElement *element in menu.children)
        flattenMenu(element, actions);

    if (g_foundUnsupportedElement || actions.count == 0) {
        maxlog(@"menu: cv not interceptable (deferred/empty, %lu actions) — system fallback",
               (unsigned long)actions.count);
        return config;
    }

    UIView *cell = [collectionView cellForItemAtIndexPath:indexPath];
    if (!cell) {
        maxlog(@"menu: cv path — no cell at index path — system fallback");
        return config;
    }

    if (![MAXMenuOverlay presentWithActions:actions cell:cell]) {
        maxlog(@"menu: cv overlay present failed — system fallback");
        return config;
    }

    return nil;
}

// ============================================================================
#pragma mark - Telegram-style menu overlay (implementation)
// ============================================================================

static UIWindow *max_currentWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindow *key = ((UIWindowScene *)scene).keyWindow;
        if (key) return key;
        for (UIWindow *w in ((UIWindowScene *)scene).windows)
            if (w) return w;
    }
    return UIApplication.sharedApplication.keyWindow;
}

// A menu row: fixed-size leading icon + left-aligned title, Telegram-like.
@interface MAXMenuItemButton : UIButton
@end

@implementation MAXMenuItemButton {
    UIView *_highlightView;
}

- (instancetype)initWithFrame:(CGRect)frame action:(UIAction *)action {
    if ((self = [super initWithFrame:frame])) {
        UIColor *tint = UIColor.labelColor;
        if (action.attributes & UIMenuElementAttributesDestructive)
            tint = [UIColor systemRedColor];

        UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
        cfg.titleAlignment = UIButtonConfigurationTitleAlignmentLeading;
        cfg.imagePlacement = NSDirectionalRectEdgeLeading;
        cfg.imagePadding = 14;
        cfg.baseForegroundColor = tint;
        cfg.attributedTitle = [[NSAttributedString alloc]
            initWithString:action.title attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightRegular],
                NSForegroundColorAttributeName: tint,
            }];
        if (action.image) {
            // normalize every icon to a fixed 24pt box so rows align
            UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc]
                initWithSize:CGSizeMake(24, 24)];
            UIImage *norm = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                CGRect dst = CGRectMake((24 - action.image.size.width) / 2,
                                        (24 - action.image.size.height) / 2,
                                        action.image.size.width, action.image.size.height);
                [action.image drawInRect:dst];
            }];
            cfg.image = [norm imageWithTintColor:tint
                                 renderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        cfg.contentInsets = NSDirectionalEdgeInsetsMake(0, 16, 0, 16);
        self.configuration = cfg;
        self.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;

        // fire the app's own handler on tap
        [self addAction:action forControlEvents:UIControlEventPrimaryActionTriggered];

        _highlightView = [[UIView alloc] initWithFrame:self.bounds];
        _highlightView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _highlightView.backgroundColor =
            [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
                return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                    ? [UIColor colorWithWhite:1 alpha:0.10]
                    : [UIColor colorWithWhite:0 alpha:0.06];
            }];
        _highlightView.layer.cornerRadius = 10;
        _highlightView.hidden = YES;
        [self insertSubview:_highlightView atIndex:0];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    _highlightView.hidden = !highlighted;
}

@end

static MAXMenuOverlay *g_overlay = nil;

@implementation MAXMenuOverlay {
    UIControl *_background;        // tap-outside to dismiss
    UIImageView *_snapshotView;    // Telegram-style "lifted" message
    UIView *_panel;
    BOOL _itemFired;
}

+ (BOOL)isShowing { return g_overlay != nil; }

// YES while a live (not dismissing) overlay is up — used to swallow repeated
// delegate calls for the same long-press without eating a fresh one.
+ (BOOL)shouldSkip {
    return g_overlay != nil && !g_overlay->_itemFired;
}

- (void)dismissAnimated:(BOOL)animated {
    UIView *snapshot = _snapshotView;
    void (^finish)(void) = ^void(void) {
        [g_overlay removeFromSuperview];
        g_overlay = nil;
    };
    if (!animated) { finish(); return; }
    [UIView animateWithDuration:0.14 delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        _background.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0];
        _panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
        _panel.alpha = 0;
        snapshot.transform = CGAffineTransformIdentity;
        snapshot.alpha = 0;
    } completion:^(BOOL f) { finish(); }];
}

- (void)tapOutside {
    if (_itemFired) return;
    maxlog(@"overlay: tap outside — dismiss");
    _itemFired = YES;
    [self dismissAnimated:YES];
}

- (void)itemTapped:(UIButton *)sender {
    if (_itemFired) return;
    NSString *title = sender.configuration.attributedTitle.string
                      ?: sender.currentTitle ?: @"?";
    maxlog(@"overlay: tapped '%@' — dismissing, firing app handler", title);
    _itemFired = YES;
    [self dismissAnimated:YES];
}

+ (BOOL)presentWithActions:(NSArray<UIAction *> *)actions cell:(UIView *)cell {
    UIWindow *window = cell.window ?: max_currentWindow();
    if (!window || !cell.superview) return NO;

    if (g_overlay) [(MAXMenuOverlay *)g_overlay dismissAnimated:NO];

    // Telegram-style lifted bubble: snapshot of the long-pressed cell.
    UIImage *snapshot = nil;
    @try {
        UIGraphicsImageRenderer *r =
            [[UIGraphicsImageRenderer alloc] initWithSize:cell.bounds.size];
        snapshot = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [cell drawViewHierarchyInRect:cell.bounds afterScreenUpdates:NO];
        }];
    } @catch (NSException *e) {
        snapshot = nil;
    }

    CGRect cellFrame = [cell convertRect:cell.bounds toView:window];

    MAXMenuOverlay *ov = [[MAXMenuOverlay alloc] initWithFrame:window.bounds];
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    g_overlay = ov;

    // dim background + tap-outside
    UIControl *bg = [[UIControl alloc] initWithFrame:window.bounds];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0];
    [bg addTarget:ov action:@selector(tapOutside)
                 forControlEvents:UIControlEventPrimaryActionTriggered];
    [ov addSubview:bg];
    ov->_background = bg;

    // panel with blur material
    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.layer.cornerRadius = 14;
    panel.layer.masksToBounds = YES;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    [ov addSubview:panel];
    ov->_panel = panel;

    UIVisualEffectView *blur =
        [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    [panel addSubview:blur];

    // ---- rows + separators
    CGFloat const rowH = 46.0;
    CGFloat const maxPanelWidth = 300.0;
    CGFloat textWidth = 0;
    for (UIAction *a in actions) {
        CGSize sz = [a.title sizeWithAttributes:
            @{NSFontAttributeName: [UIFont systemFontOfSize:17]}];
        textWidth = MAX(textWidth, sz.width);
    }
    // icon(24) + imagePadding(14) + leading inset(16) + trailing(20) + slack
    CGFloat panelWidth = MIN(MAX(textWidth + 24 + 14 + 16 + 20 + 10, 220), maxPanelWidth);

    CGFloat y = 5;
    for (NSUInteger i = 0; i < actions.count; i++) {
        UIAction *action = actions[i];
        MAXMenuItemButton *btn =
            [[MAXMenuItemButton alloc] initWithFrame:CGRectMake(0, y, panelWidth, rowH)
                                              action:action];
        [btn addTarget:ov action:@selector(itemTapped:)
              forControlEvents:UIControlEventPrimaryActionTriggered];
        [blur.contentView addSubview:btn];
        y += rowH;
        if (i + 1 < actions.count) {
            UIView *sep = [[UIView alloc]
                initWithFrame:CGRectMake(16, y, panelWidth - 32, 0.5)];
            sep.backgroundColor =
                [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
                    return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                        ? [UIColor colorWithWhite:1 alpha:0.12]
                        : [UIColor colorWithWhite:0 alpha:0.10];
                }];
            [blur.contentView addSubview:sep];
            y += 0.5;
        }
    }
    y += 5;

    panel.frame = CGRectMake(0, 0, panelWidth, y);
    blur.frame = panel.bounds;
    blur.contentView.frame = blur.bounds;

    // ---- position (Telegram-like): menu vertically centered on the message,
    // horizontally clamped inside the screen; below/above when it doesn't fit.
    CGFloat const margin = 10.0;
    CGFloat wx = cellFrame.origin.x + (cellFrame.size.width - panelWidth) / 2;
    wx = MAX(margin, MIN(wx, window.bounds.size.width - panelWidth - margin));

    CGFloat panelH = panel.bounds.size.height;
    CGFloat cy = CGRectGetMidY(cellFrame);
    CGFloat wy;
    if (cy - panelH / 2 >= margin + 40 &&
        cy + panelH / 2 <= window.bounds.size.height - margin - 40) {
        wy = cy - panelH / 2;                      // centered on the message
    } else if (CGRectGetMaxY(cellFrame) + panelH + 12 <=
               window.bounds.size.height - margin - 40) {
        wy = CGRectGetMaxY(cellFrame) + 12;        // below
    } else {
        wy = cellFrame.origin.y - panelH - 12;     // above
        if (wy < margin + 40) wy = margin + 40;    // keep clear of status bar
    }
    panel.center = CGPointMake(wx + panelWidth / 2, wy + panelH / 2);

    // ---- lifted snapshot above the cell
    if (snapshot) {
        UIImageView *snapView = [[UIImageView alloc] initWithFrame:cellFrame];
        snapView.image = snapshot;
        snapView.layer.shadowColor = [UIColor blackColor].CGColor;
        snapView.layer.shadowOpacity = 0.30;
        snapView.layer.shadowRadius = 16;
        snapView.layer.shadowOffset = CGSizeZero;
        [ov addSubview:snapView];
        ov->_snapshotView = snapView;
    }

    [window addSubview:ov];

    UIImpactFeedbackGenerator *haptic =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];

    // log the offered actions
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (UIAction *a in actions) [titles addObject:(a.title ?: @"?")];
    maxlog(@"overlay: presenting %lu actions: %@",
           (unsigned long)actions.count, [titles componentsJoinedByString:@", "]);

    // entrance animation
    UIImageView *snapView = ov->_snapshotView;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    panel.alpha = 0;
    if (snapView) {
        snapView.alpha = 0;
        snapView.transform = CGAffineTransformMakeTranslation(0, 6);
    }
    [UIView animateWithDuration:0.18 delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        panel.transform = CGAffineTransformIdentity;
        panel.alpha = 1;
        bg.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.10];
        if (snapView) {
            snapView.alpha = 1;
            snapView.transform = CGAffineTransformIdentity;
        }
    } completion:nil];

    return YES;
}

@end

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
    maxlog(@"v5.0 loading (polished custom menu, system menu unusable)...");

    // 1) Capture the app's actionProvider for message-cell menus.
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

    maxlog(@"v5.0 loaded OK — log file: %@", max_logPath());
}

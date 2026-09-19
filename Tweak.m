/**
 * MAXMods v12.3 — «Потужно Мессенджер»
 * v12.3: mod.read OFF actually sends receipts (dedicated orig IMP, no nil
 * fallback); reaction-read hooked too; Telegram overlay gets blur +
 * Потужно blue/yellow; in-app MAX strings swapped at runtime.
 * v12.2: menu action actually fires after dismiss; ghost-hook no longer
 * recurses through subclasses; tab-bar long-press attaches to the bar
 * (not the whole VC view); swizzle never mutates superclass Methods.
 * Custom overlay menu, ads/tracker prune, session persistence after re-sign,
 * file logging (Documents/maxmods_log.txt) + main-thread watchdog.
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
#import <objc/message.h>
#import <signal.h>
#import <execinfo.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <stdio.h>
#import <stdlib.h>
#import <pthread.h>


// ============================================================================
#pragma mark - Swizzle helpers
// ============================================================================

static IMP swizzle(Class cls, SEL sel, IMP newImp) {
    if (!cls || !sel || !newImp) return NULL;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NULL;
    IMP orig = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    // class_addMethod first: if `sel` is only inherited, this installs an
    // override on `cls` and leaves the superclass IMP untouched.
    if (class_addMethod(cls, sel, newImp, types)) return orig;
    return method_setImplementation(method, newImp);
}

static IMP swizzleClassMethod(Class cls, SEL sel, IMP newImp) {
    if (!cls || !sel || !newImp) return NULL;
    Method method = class_getClassMethod(cls, sel);
    if (!method) return NULL;
    IMP orig = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    Class meta = object_getClass((id)cls);
    if (class_addMethod(meta, sel, newImp, types)) return orig;
    return method_setImplementation(method, newImp);
}

// Method implemented on `cls` itself (not inherited). method_setImplementation
// on class_getInstanceMethod() would otherwise mutate the superclass Method
// and every subsequent subclass lookup would capture the hook as "orig".
static Method max_ownInstanceMethod(Class cls, SEL sel) {
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    if (!list) return NULL;
    Method found = NULL;
    for (unsigned i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { found = list[i]; break; }
    }
    free(list);
    return found;
}

// Replace an own method, or add a per-class override of an inherited one.
// Never writes the superclass Method.
static BOOL max_replaceMethod(Class cls, SEL sel, IMP hook) {
    Method own = max_ownInstanceMethod(cls, sel);
    if (own) {
        method_setImplementation(own, hook);
        return YES;
    }
    Method inherited = class_getInstanceMethod(cls, sel);
    if (!inherited) return NO;
    return class_addMethod(cls, sel, hook, method_getTypeEncoding(inherited));
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

static dispatch_queue_t max_logQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("ru.oneme.maxmods.log", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// v12.4 FULL-LOG: synchronous crash-safe logger.
// Every line is written with open/write/fsync immediately on the caller thread,
// so a SIGSEGV right after the line still leaves it on disk. The serial queue
// is kept only for truncation — the data path no longer depends on it.
static void maxlog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"[MAXMods] %@", msg);

    NSString *path = max_logPath();
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    // SYNC write: open-append-fsync-close on the caller thread
    @try {
        const char *cpath = path.fileSystemRepresentation;
        int fd = open(cpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            const void *bytes = data.bytes;
            size_t len = data.length;
            // handle partial writes
            size_t off = 0;
            while (off < len) {
                ssize_t w = write(fd, (const char *)bytes + off, len - off);
                if (w <= 0) break;
                off += (size_t)w;
            }
            fsync(fd);
            close(fd);
        }
    } @catch (NSException *e) { (void)e; }

    // keep the file bounded (async, best-effort)
    dispatch_async(max_logQueue(), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        // atomically:NO keeps the same inode so g_crashFd stays valid
        if ([attrs fileSize] > 3 * 1024 * 1024) {
            NSString *full = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            if (full.length > 0) {
                NSArray *lines = [full componentsSeparatedByString:@"\n"];
                if (lines.count > 1500) {
                    lines = [lines subarrayWithRange:NSMakeRange(lines.count - 1500, 1500)];
                    NSString *trimmed = [lines componentsJoinedByString:@"\n"];
                    [trimmed writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
                    NSString *marker = [NSString stringWithFormat:@"%@ | log: truncated to last 1500 lines\n", [NSDate date]];
                    NSData *md = [marker dataUsingEncoding:NSUTF8StringEncoding];
                    int fd2 = open(path.fileSystemRepresentation, O_WRONLY|O_CREAT|O_APPEND, 0644);
                    if (fd2 >= 0) { write(fd2, md.bytes, md.length); fsync(fd2); close(fd2); }
                }
            }
        }
    });
}

// Verbose helper: logs selector + object descriptions, safe for nil
static NSString *max_desc(id obj) {
    if (!obj) return @"nil";
    @try { return [obj description] ?: @"<no desc>"; }
    @catch (NSException *e) { return [NSString stringWithFormat:@"<exc %@>", e.name]; }
}

// v12.4 FULL-LOG watchdog: every 5s checks main thread. On stuck it dumps
// the main thread's call stack via NSThread + backtrace so we see WHERE it hung.
static void max_scheduleWatchdog(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{ dispatch_semaphore_signal(sem); });
        if (dispatch_semaphore_wait(sem,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC))) != 0) {
            NSArray *stack = [NSThread callStackSymbols];
            if (stack.count > 40) stack = [stack subarrayWithRange:NSMakeRange(0, 40)];
            maxlog(@"WATCHDOG: MAIN THREAD STUCK >2s — app frozen — stack:\n%@", [stack componentsJoinedByString:@"\n"]);
            dispatch_sync(max_logQueue(), ^{});
        }
        max_scheduleWatchdog();
    });
}

// ============================================================================
#pragma mark - Crash catcher (v9.2)
//
// The delete flow now completes cleanly up to "server-delete fired", yet the
// app still dies right after — inside the async handling of the server's
// response. That path is not an NSException (our @try can't see it), so we
// install signal handlers for the fatal signals plus an uncaught-exception
// hook. Both write the native backtrace into maxmods_log.txt synchronously
// before the process dies, so the NEXT log pinpoints the exact crash site.
// ============================================================================

static volatile sig_atomic_t g_inCrashHandler = 0;
static int g_crashFd = -1;   // cached at install time: no ObjC in the handler
static BOOL g_blockRead = YES;   // declared early: crash dump reads it (ON until toggled)

static void max_crashLog(const char *reason) {
    if (g_inCrashHandler) return;
    g_inCrashHandler = 1;
    int fd = g_crashFd;
    if (fd < 0) return;
    void *frames[96];
    int n = backtrace(frames, 96);
    char header[512];
    int len = snprintf(header, sizeof(header),
        "\n========== CRASH ==========\n%s (pid %d, tid %lu) — backtrace %d frames:\n",
        reason, (int)getpid(), (unsigned long)pthread_self(), n);
    if (len > 0) { write(fd, header, (size_t)len); }
    if (n > 0) {
        char **syms = backtrace_symbols(frames, (size_t)n);
        if (syms) {
            for (int i = 0; i < n; i++) {
                if (!syms[i]) continue;
                int l = (int)strlen(syms[i]);
                write(fd, syms[i], (size_t)l);
                write(fd, "\n", 1);
            }
            free(syms);
        } else {
            for (int i = 0; i < n; i++) {
                char line[64];
                int ll = snprintf(line, sizeof(line), "  [%d] %p\n", i, frames[i]);
                if (ll > 0) write(fd, line, (size_t)ll);
            }
        }
    }
    {
        char extra[256];
        int el = snprintf(extra, sizeof(extra),
            "g_blockRead=%d  g_inCrashHandler=%d\n===========================\n\n",
            (int)g_blockRead, (int)g_inCrashHandler);
        if (el > 0) write(fd, extra, (size_t)el);
    }
    fsync(fd);
}

static void max_signalHandler(int sig, siginfo_t *info, void *ctx) {
    (void)ctx;
    char buf[128];
    snprintf(buf, sizeof(buf), "signal %d code=%d addr=%p", sig, info ? info->si_code : 0, info ? info->si_addr : NULL);
    max_crashLog(buf);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void max_uncaughtException(NSException *e) {
    // synchronous: must hit disk before the runtime kills us
    NSString *msg = [NSString stringWithFormat:@"CRASH: UNCAUGHT EXCEPTION %@ — %@\n%@", e.name, e.reason, e.callStackSymbols];
    NSLog(@"[MAXMods] %@", msg);
    @try {
        NSString *path = max_logPath();
        NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        int fd = open(path.fileSystemRepresentation, O_WRONLY|O_CREAT|O_APPEND, 0644);
        if (fd >= 0) { write(fd, data.bytes, data.length); fsync(fd); close(fd); }
        if (g_crashFd >= 0) { write(g_crashFd, data.bytes, data.length); fsync(g_crashFd); }
    } @catch (NSException *ee) { (void)ee; }
    // also call normal path for truncation logic
    maxlog(@"CRASH: UNCAUGHT EXCEPTION %@ — %@", e.name, e.reason);
}

static void max_installCrashCatcher(void) {
    NSString *path = max_logPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    g_crashFd = open(path.fileSystemRepresentation,
                     O_WRONLY | O_CREAT | O_APPEND | O_SYNC, 0644);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = max_signalHandler;
    sa.sa_flags = SA_SIGINFO;
    const int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGTRAP, SIGILL, SIGFPE };
    for (size_t i = 0; i < sizeof(sigs)/sizeof(sigs[0]); i++)
        sigaction(sigs[i], &sa, NULL);
    NSSetUncaughtExceptionHandler(max_uncaughtException);
    maxlog(@"crash-catcher: installed (SIGSEGV/ABRT/BUS/TRAP/ILL/FPE + NSException)");
}

// ============================================================================
#pragma mark - Telegram-style menu overlay (interface)
// ============================================================================

@interface MAXMenuOverlay : UIView
+ (BOOL)isShowing;
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
    if (!orig_configCreate) return nil;
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
#pragma mark - System-menu hang diagnostics (v11.2)
//
// The original bug that started this project: the SYSTEM context menu froze
// the whole app on long-press. We replaced it with our overlay; now let's
// find out WHY the system one hangs. When mod.sysmenu is ON (Моды tab):
//   - our overlay is bypassed, the stock system menu is shown
//   - every phase of the interaction is logged BEFORE/AFTER the original
//     call: configuration -> willDisplay -> previewForHighlighting ->
//     previewForDismissing -> willEnd
// If the app freezes, the LAST "before" marker names the method that hung.
// ============================================================================

static BOOL max_modOn(NSString *key);   // defined in the mods section below

static IMP orig_willDisplayMenu = NULL;
static IMP orig_willEndMenu = NULL;
static IMP orig_previewHighlight = NULL;
static IMP orig_previewDismiss = NULL;

static void hook_willDisplayMenu(id self, SEL _cmd, id interaction, id config, id animator) {
    if (max_modOn(@"mod.sysmenu")) maxlog(@"SYSMENU: willDisplay BEFORE");
    if (orig_willDisplayMenu)
        ((void(*)(id,SEL,id,id,id))orig_willDisplayMenu)(self, _cmd, interaction, config, animator);
    if (max_modOn(@"mod.sysmenu")) maxlog(@"SYSMENU: willDisplay AFTER");
}

static void hook_willEndMenu(id self, SEL _cmd, id interaction, id config, id animator) {
    if (max_modOn(@"mod.sysmenu")) maxlog(@"SYSMENU: willEnd BEFORE");
    if (orig_willEndMenu)
        ((void(*)(id,SEL,id,id,id))orig_willEndMenu)(self, _cmd, interaction, config, animator);
    if (max_modOn(@"mod.sysmenu")) maxlog(@"SYSMENU: willEnd AFTER");
}

static id hook_previewHighlight(id self, SEL _cmd, id interaction, id config) {
    if (max_modOn(@"mod.sysmenu")) maxlog(@"SYSMENU: previewHighlight BEFORE");
    id r = orig_previewHighlight
        ? ((id(*)(id,SEL,id,id))orig_previewHighlight)(self, _cmd, interaction, config)
        : nil;
    if (max_modOn(@"mod.sysmenu")) maxlog(@"SYSMENU: previewHighlight AFTER");
    return r;
}

static id hook_previewDismiss(id self, SEL _cmd, id interaction, id config) {
    if (max_modOn(@"mod.sysmenu")) maxlog(@"SYSMENU: previewDismiss BEFORE");
    id r = orig_previewDismiss
        ? ((id(*)(id,SEL,id,id))orig_previewDismiss)(self, _cmd, interaction, config)
        : nil;
    if (max_modOn(@"mod.sysmenu")) maxlog(@"SYSMENU: previewDismiss AFTER");
    return r;
}

static void max_installSysmenuDiagnostics(void) {
    Class cell = objc_getClass("_TtC13ChatHistoryUI11MessageCell");
    if (!cell) { maxlog(@"SYSMENU: MessageCell not found"); return; }
    struct { SEL sel; IMP *orig; IMP hook; const char *name; } hooks[] = {
        { @selector(contextMenuInteraction:willDisplayMenuForConfiguration:animator:),
          &orig_willDisplayMenu, (IMP)hook_willDisplayMenu, "willDisplay" },
        { @selector(contextMenuInteraction:willEndForConfiguration:animator:),
          &orig_willEndMenu, (IMP)hook_willEndMenu, "willEnd" },
        { @selector(contextMenuInteraction:previewForHighlightingMenuWithConfiguration:),
          &orig_previewHighlight, (IMP)hook_previewHighlight, "previewHighlight" },
        { @selector(contextMenuInteraction:previewForDismissingMenuWithConfiguration:),
          &orig_previewDismiss, (IMP)hook_previewDismiss, "previewDismiss" },
    };
    for (NSUInteger i = 0; i < sizeof(hooks)/sizeof(hooks[0]); i++) {
        IMP orig = swizzle(cell, hooks[i].sel, hooks[i].hook);
        if (!orig) {
            maxlog(@"SYSMENU: %@ not found — skipping", @(hooks[i].name));
            continue;
        }
        *hooks[i].orig = orig;
        maxlog(@"SYSMENU: trace hook on %@", @(hooks[i].name));
    }
}

// ============================================================================
#pragma mark - Hook: -[MessageCell contextMenuInteraction:configurationForMenuAtLocation:]
// ============================================================================

static IMP orig_cellConfig = NULL;

// the cell the menu was opened on (weak; used to record its indexPath
// when the message gets marked by the two-phase delete)
@interface MaxMenuCellRef : NSObject
@property (nonatomic, weak) id target;
@end
@implementation MaxMenuCellRef
@end
static MaxMenuCellRef *g_lastMenuCellRef = nil;

static UIContextMenuConfiguration *hook_cellConfig(
        id self, SEL _cmd, UIContextMenuInteraction *interaction, CGPoint point) {

    maxlog(@"menu: entry (MessageCell path)");
    if (!orig_cellConfig) return nil;
    if (!g_lastMenuCellRef) g_lastMenuCellRef = [MaxMenuCellRef new];
    g_lastMenuCellRef.target = self;
    g_capturedProvider = nil;
    g_foundUnsupportedElement = NO;
    g_inMessageCellMenu = YES;
    UIContextMenuConfiguration *config = nil;
    @try {
        config = ((UIContextMenuConfiguration *(*)(id,SEL,id,CGPoint))orig_cellConfig)(
            self, _cmd, interaction, point);
    } @finally {
        g_inMessageCellMenu = NO;
    }

    // v11.2 diagnostics: user-toggled system menu — pass the stock config
    // through untouched, no overlay, full phase logging
    if (max_modOn(@"mod.sysmenu")) {
        maxlog(@"SYSMENU: config returned (system menu will show)");
        return config;
    }

    if (!g_capturedProvider) {
        maxlog(@"menu: no provider captured — system fallback");
        return config;   // preview-only menu — keep system behavior
    }

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
    if (!orig_cvConfig) return nil;
    g_capturedProvider = nil;
    g_foundUnsupportedElement = NO;
    g_inMessageCellMenu = YES;
    UIContextMenuConfiguration *config = nil;
    @try {
        config = ((UIContextMenuConfiguration *(*)(id,SEL,id,id,CGPoint))orig_cvConfig)(
            self, _cmd, collectionView, indexPath, point);
    } @finally {
        g_inMessageCellMenu = NO;
    }

    // v11.2 diagnostics: system menu passthrough
    if (max_modOn(@"mod.sysmenu")) {
        maxlog(@"SYSMENU: cv config returned (system menu will show)");
        return config;
    }

    if (!g_capturedProvider) {
        maxlog(@"menu: cv path — no provider captured — system fallback");
        return config;
    }

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

static UIColor *max_potuzhnoBlue(void) {
    return [UIColor colorWithRed:0.0 green:87.0/255.0 blue:183.0/255.0 alpha:1.0];
}
static UIColor *max_potuzhnoYellow(void) {
    return [UIColor colorWithRed:1.0 green:215.0/255.0 blue:0.0 alpha:1.0];
}

// A menu row: fixed-size leading icon + left-aligned title, laid out by hand.
// UIButtonConfiguration misaligned icons over long titles (icon overlapping
// "Delete", truncated "Save to Gallery") — manual layout is predictable.
@interface MAXMenuItemButton : UIControl
@property (nonatomic, strong, readonly) NSString *actionTitle;
@property (nonatomic, strong, readonly) UIAction *action;
- (instancetype)initWithFrame:(CGRect)frame action:(UIAction *)action;
@end

@interface MAXMenuItemButton ()
@property (nonatomic, strong, readwrite) UIAction *action;
@property (nonatomic, strong) UILabel *titleLabel2;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UIView *highlightView;
@end

@implementation MAXMenuItemButton

- (instancetype)initWithFrame:(CGRect)frame action:(UIAction *)action {
    if ((self = [super initWithFrame:frame])) {
        UIColor *tint = max_potuzhnoBlue();
        if (action.attributes & UIMenuElementAttributesDestructive)
            tint = [UIColor systemRedColor];
        _action = action;
        _actionTitle = action.title ?: @"";

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
        [self addSubview:_highlightView];

        _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _iconView.contentMode = UIViewContentModeCenter;
        if (action.image) {
            // normalize to a fixed 24x24 box, centered
            UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc]
                initWithSize:CGSizeMake(24, 24)];
            UIImage *norm = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                CGRect dst = CGRectMake((24 - action.image.size.width) / 2,
                                        (24 - action.image.size.height) / 2,
                                        action.image.size.width, action.image.size.height);
                [action.image drawInRect:dst];
            }];
            _iconView.image = [norm imageWithTintColor:tint
                                        renderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        [self addSubview:_iconView];

        _titleLabel2 = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel2.text = action.title;
        _titleLabel2.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        _titleLabel2.textColor = tint;
        _titleLabel2.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_titleLabel2];
        // The overlay owns the tap: it dismisses first, then calls -fire.
        // Adding a TouchUpInside target here would fire the app handler twice.
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat const iconX = 18, iconSize = 24, gap = 14, trailing = 16;
    _iconView.frame = CGRectMake(iconX,
                                 (self.bounds.size.height - iconSize) / 2,
                                 iconSize, iconSize);
    CGFloat textX = iconX + iconSize + gap;
    _titleLabel2.frame = CGRectMake(textX, 0,
        self.bounds.size.width - textX - trailing, self.bounds.size.height);
}

- (void)fire {
    UIAction *action = _action;
    if (!action) return;
    // UIAction.performWithSender:target: is the documented way to invoke the
    // handler. A throwaway UIControl + sendActions was racy: the overlay was
    // already tearing down, and the ghost control never stayed in a window.
    if ([action respondsToSelector:@selector(performWithSender:target:)]) {
        [action performWithSender:self target:nil];
        return;
    }
    UIControl *ghost = [[UIControl alloc] initWithFrame:CGRectZero];
    [ghost addAction:action forControlEvents:UIControlEventPrimaryActionTriggered];
    [ghost sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
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
    UIView *_panel;                // shadow wrapper around the blur card
    BOOL _itemFired;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || !self.userInteractionEnabled || self.alpha < 0.01)
        return nil;
    // Snapshot of the bubble is decorative — never steal taps from the panel
    // or from the dimmed background (tap-outside dismiss).
    if (_panel) {
        CGPoint inPanel = [self convertPoint:point toView:_panel];
        if ([_panel pointInside:inPanel withEvent:event]) {
            UIView *hit = [_panel hitTest:inPanel withEvent:event];
            return hit ?: _panel;
        }
    }
    return _background ?: [super hitTest:point withEvent:event];
}

+ (BOOL)isShowing { return g_overlay != nil; }

- (void)dismissAnimated:(BOOL)animated {
    [self dismissAnimated:animated then:nil];
}

- (void)dismissAnimated:(BOOL)animated then:(void (^)(void))then {
    UIView *snapshot = _snapshotView;
    void (^finish)(void) = ^void(void) {
        [g_overlay removeFromSuperview];
        g_overlay = nil;
        if (then) then();
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

// Dismiss on tap outside the panel (TouchUpInside on the full-screen bg).
- (void)tapOutside {
    if (_itemFired) return;
    maxlog(@"overlay: tap outside — dismiss");
    _itemFired = YES;
    [self dismissAnimated:YES];
}

- (void)itemTapped:(MAXMenuItemButton *)sender {
    if (_itemFired) return;
    NSString *title = sender.actionTitle ?: @"?";
    maxlog(@"overlay: tapped '%@' — dismissing, firing app handler", title);
    _itemFired = YES;
    // Capture the UIAction (not the button): dismiss deallocates the overlay
    // tree. Fire only after the covering view is gone — some app handlers
    // present alerts / mutate the collection and deadlock under our overlay.
    UIAction *action = sender.action;
    [self dismissAnimated:YES then:^{
        if (!action) return;
        if ([action respondsToSelector:@selector(performWithSender:target:)])
            [action performWithSender:nil target:nil];
    }];
}

+ (BOOL)presentWithActions:(NSArray<UIAction *> *)actions cell:(UIView *)cell {
    UIWindow *window = cell.window ?: max_currentWindow();
    if (!window || !cell.superview) return NO;

    if (g_overlay) [(MAXMenuOverlay *)g_overlay dismissAnimated:NO];

    CGRect cellFrame = [cell convertRect:cell.bounds toView:window];

    MAXMenuOverlay *ov = [[MAXMenuOverlay alloc] initWithFrame:window.bounds];
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    g_overlay = ov;

    // dim background + tap-outside to dismiss
    UIControl *bg = [[UIControl alloc] initWithFrame:window.bounds];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0];
    // TouchUpInside only. TouchDown would fire before the panel's button
    // receives the same event (hit-testing walks siblings, but a simultaneous
    // TouchDown on the full-screen bg raced the row tap and ate the action).
    [bg addTarget:ov action:@selector(tapOutside)
                 forControlEvents:UIControlEventTouchUpInside];
    [ov addSubview:bg];
    ov->_background = bg;

    // Telegram-style lifted bubble: snapshot of the long-pressed cell,
    // placed UNDER the panel (panel must draw above the message).
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
    if (snapshot) {
        UIImageView *snapView = [[UIImageView alloc] initWithFrame:cellFrame];
        snapView.image = snapshot;
        snapView.userInteractionEnabled = NO;
        snapView.layer.shadowColor = [UIColor blackColor].CGColor;
        snapView.layer.shadowOpacity = 0.30;
        snapView.layer.shadowRadius = 16;
        snapView.layer.shadowOffset = CGSizeZero;
        [ov addSubview:snapView];
        ov->_snapshotView = snapView;
    }

    // Card: shadow wrapper + material blur. Solid fill previously looked
    // cheap against chat wallpaper; blur + Потужно flag strip is the
    // replacement chrome for MAX's system menu.
    BOOL dark = window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.layer.cornerRadius = 16;
    panel.layer.shadowColor = max_potuzhnoBlue().CGColor;
    panel.layer.shadowOpacity = dark ? 0.45 : 0.22;
    panel.layer.shadowRadius = 18;
    panel.layer.shadowOffset = CGSizeMake(0, 8);
    [ov addSubview:panel];
    ov->_panel = panel;

    UIBlurEffectStyle style = dark
        ? UIBlurEffectStyleSystemMaterialDark
        : UIBlurEffectStyleSystemMaterialLight;
    UIVisualEffectView *blur =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:style]];
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.layer.cornerRadius = 16;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.layer.masksToBounds = YES;
    blur.layer.borderWidth = 0.5;
    blur.layer.borderColor = [max_potuzhnoBlue() colorWithAlphaComponent:dark ? 0.45 : 0.28].CGColor;
    [panel addSubview:blur];

    UIView *rowsHost = blur.contentView;

    // ---- rows + separators
    CGFloat const rowH = 48.0;
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
              forControlEvents:UIControlEventTouchUpInside];
        [rowsHost addSubview:btn];
        y += rowH;
        if (i + 1 < actions.count) {
            UIView *sep = [[UIView alloc]
                initWithFrame:CGRectMake(16, y, panelWidth - 32, 0.5)];
            sep.backgroundColor = [max_potuzhnoBlue() colorWithAlphaComponent:dark ? 0.28 : 0.16];
            [rowsHost addSubview:sep];
            y += 0.5;
        }
    }
    y += 5;

    panel.frame = CGRectMake(0, 0, panelWidth, y);
    blur.frame = panel.bounds;

    // Flag strip on the leading edge (blue over yellow).
    CGFloat const stripW = 3.0;
    UIView *blueStrip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, stripW, y / 2.0)];
    blueStrip.backgroundColor = max_potuzhnoBlue();
    UIView *yellowStrip = [[UIView alloc] initWithFrame:CGRectMake(0, y / 2.0, stripW, y / 2.0)];
    yellowStrip.backgroundColor = max_potuzhnoYellow();
    [rowsHost addSubview:blueStrip];
    [rowsHost addSubview:yellowStrip];

    // ---- position (Telegram-like): menu ABOVE the message bubble,
    // below if there's no room above; horizontally centered on the bubble,
    // clamped inside the screen.
    CGFloat const margin = 10.0;
    CGFloat const safeTop = 54.0;    // status bar / dynamic island
    CGFloat const safeBottom = 40.0;
    CGFloat wx = cellFrame.origin.x + (cellFrame.size.width - panelWidth) / 2;
    wx = MAX(margin, MIN(wx, window.bounds.size.width - panelWidth - margin));

    CGFloat panelH = panel.bounds.size.height;
    CGFloat wy;
    if (cellFrame.origin.y - panelH - 10 >= safeTop) {
        wy = cellFrame.origin.y - panelH - 10;               // above the bubble
    } else if (CGRectGetMaxY(cellFrame) + panelH + 10 <=
               window.bounds.size.height - safeBottom) {
        wy = CGRectGetMaxY(cellFrame) + 10;                  // below
    } else {
        // neither fits: clamp to the safe area (bubble is tall on screen)
        wy = MAX(safeTop, MIN(cellFrame.origin.y - panelH - 6,
                              window.bounds.size.height - safeBottom - panelH));
    }
    panel.center = CGPointMake(wx + panelWidth / 2, wy + panelH / 2);

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
    [UIView animateWithDuration:0.32 delay:0
         usingSpringWithDamping:0.82 initialSpringVelocity:0.45
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        panel.transform = CGAffineTransformIdentity;
        panel.alpha = 1;
        bg.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.28];
        if (snapView) {
            snapView.alpha = 1;
            snapView.transform = CGAffineTransformIdentity;
        }
    } completion:nil];

    return YES;
}

@end

// ============================================================================
#pragma mark - Ad & junk blocker
//
// Kill the promo/banners/suggested content entirely:
//  - OKMInAppBannerPresenter.showPromoBannerWith...  -> no promo ever shown
//  - InformerBannerFetcher.fetchRemoteNotifBanners   -> banners never fetched
//  - SuggestedChatIdsStorage.loadChatIds             -> no suggested chats
//  - InformerBannersStorage (all reads)              -> no stored banners
//  - MRAdSupportWrapper.advertisingIdentifier        -> zeroed ad id
// The Calls tab and MyTracker are already statically patched out in the
// app binary; stats endpoints return zero via the same static patches.
// ============================================================================

static void max_hookVoidRet(id self, SEL _cmd) { (void)self; (void)_cmd; }
static id max_hookIdRetNil(id self, SEL _cmd) { (void)self; (void)_cmd; return nil; }
static BOOL max_hookBoolRetNo(id self, SEL _cmd) { (void)self; (void)_cmd; return NO; }

// storage getters return a fixed empty array
static id max_hookEmptyArrayRet(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @[];
}

// ============================================================================
#pragma mark - Brand icons: runtime substitution of every MAX logo (v12.0)
//
// The in-app MAX logos (chat header, auth screens, about page) live inside
// binary Assets.car archives that can't be rebuilt off-macOS. Instead we
// hook +[UIImage imageNamed:] and swap every MAX-brand asset for our own
// Potuzhno icon, loaded once from the app bundle (Files/ dir of the .app).
// ============================================================================

static IMP orig_imageNamed = NULL;
static NSMutableDictionary<NSString *, UIImage *> *g_brandIcons = nil;

static UIImage *max_brandIconFor(NSString *name) {
    if (!g_brandIcons || name.length == 0) return nil;
    UIImage *exact = g_brandIcons[name];
    if (exact) return exact;
    // substring match only for the explicit MAX-brand keys — never for a
    // generic name like "app_icon", which would hijack every UIImage.imageNamed:
    static NSArray<NSString *> *fuzzy = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fuzzy = @[ @"max_logo_title", @"max_solid_themed", @"logo_54px", @"max.svg" ];
    });
    for (NSString *key in fuzzy)
        if ([name rangeOfString:key options:NSCaseInsensitiveSearch].location != NSNotFound)
            return g_brandIcons[key] ?: g_brandIcons.allValues.firstObject;
    return nil;
}

static id hook_imageNamed(id self, SEL _cmd, NSString *name) {
    if (name.length > 0) {
        @try {
            UIImage *sub = max_brandIconFor(name);
            if (sub) return sub;
        } @catch (NSException *e) {}
    }
    if (orig_imageNamed)
        return ((id(*)(id,SEL,id))orig_imageNamed)(self, _cmd, name);
    return nil;
}

static void max_installBrandIcons(void) {
    // source image: our icon shipped in the app bundle root
    NSString *path = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"AppIcon60x60@2x.png"];
    UIImage *icon = [UIImage imageWithContentsOfFile:path];
    if (!icon) {
        maxlog(@"brand-icons: source AppIcon60x60@2x.png not found in bundle");
        return;
    }
    g_brandIcons = [NSMutableDictionary new];
    // every MAX-brand asset name found in the Resources Assets.car dump
    NSArray *names = @[
        @"max_logo_title", @"max_solid_themed", @"logo_54px",
        @"app_icon", @"max.svg",
    ];
    for (NSString *n in names) g_brandIcons[n] = icon;
    orig_imageNamed = swizzleClassMethod([UIImage class], @selector(imageNamed:),
                                         (IMP)hook_imageNamed);
    if (!orig_imageNamed) { maxlog(@"brand-icons: imageNamed: not found"); return; }
    maxlog(@"brand-icons: substituted %lu MAX asset name(s)",
           (unsigned long)g_brandIcons.count);
}

// ============================================================================
#pragma mark - Brand strings: MAX → Потужно (runtime)
// ============================================================================

static IMP orig_localized = NULL;
static IMP orig_infoDict = NULL;
static IMP orig_objectForInfo = NULL;
static NSBundle *g_mainBundle = nil;   // captured BEFORE any NSBundle swizzle
static BOOL g_inBrandHook = NO;

static NSString *max_rebrandString(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 3) return s;
    if ([s rangeOfString:@"MAX" options:NSCaseInsensitiveSearch].location == NSNotFound &&
        [s rangeOfString:@"макс" options:NSCaseInsensitiveSearch].location == NSNotFound)
        return s;
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(?<![\\p{L}\\p{N}_])(MAX|Max|макс|Макс|МАКС)(?![\\p{L}\\p{N}_])"
              options:0 error:nil];
    });
    if (!re) return s;
    return [re stringByReplacingMatchesInString:s options:0
                                          range:NSMakeRange(0, s.length)
                                   withTemplate:@"Потужно"];
}

static BOOL max_isDisplayInfoKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    return [key isEqualToString:@"CFBundleDisplayName"]
        || [key isEqualToString:@"NSCameraUsageDescription"]
        || [key isEqualToString:@"NSContactsUsageDescription"]
        || [key isEqualToString:@"NSLocalNetworkUsageDescription"]
        || [key isEqualToString:@"NSPhotoLibraryAddUsageDescription"]
        || [key isEqualToString:@"NSPhotoLibraryUsageDescription"];
}

static id hook_localized(id self, SEL _cmd, NSString *key, NSString *value, NSString *table) {
    id r = orig_localized
        ? ((id(*)(id,SEL,id,id,id))orig_localized)(self, _cmd, key, value, table)
        : value;
    if (g_inBrandHook) return r;
    if (self != g_mainBundle) return r;
    g_inBrandHook = YES;
    id branded = max_rebrandString(r);
    g_inBrandHook = NO;
    return branded ?: r;
}

static NSDictionary *g_brandedMainInfo = nil;

static id hook_infoDict(id self, SEL _cmd) {
    NSDictionary *d = orig_infoDict
        ? ((id(*)(id,SEL))orig_infoDict)(self, _cmd)
        : nil;
    if (g_inBrandHook) return d;
    if (self != g_mainBundle) return d;
    if (![d isKindOfClass:[NSDictionary class]]) return d;
    if (g_brandedMainInfo) return g_brandedMainInfo;

    g_inBrandHook = YES;
    NSMutableDictionary *m = [d mutableCopy];
    id dn = m[@"CFBundleDisplayName"];
    if ([dn isKindOfClass:[NSString class]]) m[@"CFBundleDisplayName"] = @"Потужно";
    // CFBundleName / CFBundleExecutable stay MAX — dyld and codesign look them up.
    static NSArray *usageKeys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        usageKeys = @[
            @"NSCameraUsageDescription", @"NSContactsUsageDescription",
            @"NSLocalNetworkUsageDescription",
            @"NSPhotoLibraryAddUsageDescription",
            @"NSPhotoLibraryUsageDescription",
        ];
    });
    for (NSString *k in usageKeys) {
        id v = m[k];
        NSString *b = max_rebrandString(v);
        if (b && ![b isEqual:v]) m[k] = b;
    }
    id alt = m[@"INAlternativeAppNames"];
    if ([alt isKindOfClass:[NSArray class]]) {
        NSMutableArray *na = [NSMutableArray array];
        for (id item in alt) {
            if ([item isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *im = [item mutableCopy];
                im[@"INAlternativeAppName"] = @"Потужно";
                [na addObject:im];
            } else {
                [na addObject:item];
            }
        }
        m[@"INAlternativeAppNames"] = na;
    }
    g_brandedMainInfo = [m copy];
    g_inBrandHook = NO;
    return g_brandedMainInfo;
}

static id hook_objectForInfo(id self, SEL _cmd, NSString *key) {
    id v = orig_objectForInfo
        ? ((id(*)(id,SEL,id))orig_objectForInfo)(self, _cmd, key)
        : nil;
    if (g_inBrandHook) return v;
    if (self != g_mainBundle) return v;
    if ([key isEqualToString:@"CFBundleDisplayName"]) return @"Потужно";
    if (!max_isDisplayInfoKey(key)) return v;   // NEVER rewrite Executable/Name/id
    g_inBrandHook = YES;
    id branded = max_rebrandString(v);
    g_inBrandHook = NO;
    return branded ?: v;
}

static void max_installBrandStrings(void) {
    g_mainBundle = [NSBundle mainBundle];
    orig_localized = swizzle([NSBundle class],
        @selector(localizedStringForKey:value:table:), (IMP)hook_localized);
    orig_infoDict = swizzle([NSBundle class],
        @selector(infoDictionary), (IMP)hook_infoDict);
    orig_objectForInfo = swizzle([NSBundle class],
        @selector(objectForInfoDictionaryKey:), (IMP)hook_objectForInfo);
    maxlog(@"brand-strings: localized %@  infoDict %@  objectForInfo %@",
           orig_localized ? @"OK" : @"MISS",
           orig_infoDict ? @"OK" : @"MISS",
           orig_objectForInfo ? @"OK" : @"MISS");
}

static void max_installAdBlocker(void) {
    // direct class hooks — each of these exists in the app binary
    struct {
        const char *cls;
        const char *sel;
        IMP hook;
    } hooks[] = {
        // promo banners in-app
        { "OKMInAppBannerPresenter",
          "showPromoBannerWithTitle:text:imageUrl:actionBlock:",
          (IMP)max_hookVoidRet },
        // chat-list "informer" banners: never fetch, never store, show none
        { "_TtC10OMChatList21InformerBannerFetcher",
          "fetchRemoteNotifBanners",
          (IMP)max_hookVoidRet },
        { "OMInformerBannersStorage", "banners", (IMP)max_hookEmptyArrayRet },
        // suggested chats
        { "_TtC10OMChatList23SuggestedChatIdsStorage",
          "loadChatIds", (IMP)max_hookEmptyArrayRet },
        { "_TtC10OMChatList23SuggestedChatIdsStorage",
          "saveChatIds:", (IMP)max_hookVoidRet },
        // myTarget ad id: zeroed, tracking off
        { "MRAdSupportWrapper", "advertisingIdentifier", (IMP)max_hookIdRetNil },
        { "MRAdSupportWrapper", "advertisingTrackingEnabled", (IMP)max_hookBoolRetNo },
    };
    for (NSUInteger i = 0; i < sizeof(hooks)/sizeof(hooks[0]); i++) {
        Class cls = objc_getClass(hooks[i].cls);
        if (!cls) {
            maxlog(@"ads: class not found: %s", hooks[i].cls);
            continue;
        }
        SEL sel = sel_registerName(hooks[i].sel);
        if (!max_replaceMethod(cls, sel, hooks[i].hook)) {
            maxlog(@"ads: method not found: %s -> %s", hooks[i].cls, hooks[i].sel);
            continue;
        }
        maxlog(@"ads: blocked %s -> %s", hooks[i].cls, hooks[i].sel);
    }
}

// ============================================================================
#pragma mark - Feature pruning: stories / Digital ID / mini-apps / channels
//
// Strip the super-app extras down to a plain messenger:
//  - storiesEnabled -> NO            (stories circles never render)
//  - Digital ID tab: router noop + filtered out of setViewControllers:
//  - mini-apps list screen: router noop
//  - channel creation: openCreateChannel noop on every implementor
// Contacts/Chats/Settings stay; the Моды tab is added by our own injector.
// ============================================================================

static BOOL max_hookBoolNo(id self, SEL _cmd) { (void)self; (void)_cmd; return NO; }
static void max_hookVoid3(id self, SEL _cmd, id a, id b, id c) {
    (void)self; (void)_cmd; (void)a; (void)b; (void)c;
}
static void max_hookVoid2(id self, SEL _cmd, id a, id b) {
    (void)self; (void)_cmd; (void)a; (void)b;
}
static void max_hookVoid1(id self, SEL _cmd, id a) { (void)self; (void)_cmd; (void)a; }
static void max_hookVoid0(id self, SEL _cmd) { (void)self; (void)_cmd; }

static IMP orig_setViewControllers = NULL;
static IMP orig_setViewControllersAnimated = NULL;

static BOOL max_isPrunedTab(UIViewController *vc) {
    if (!vc) return NO;
    NSString *cls = NSStringFromClass(vc.class);
    if ([cls rangeOfString:@"Digital" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return YES;
    NSString *title = vc.tabBarItem.title ?: @"";
    if ([title rangeOfString:@"Цифровой"].location != NSNotFound ||
        [title rangeOfString:@"Digital" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return YES;
    return NO;
}

static NSArray *max_filterTabVCs(NSArray *vcs) {
    if (![vcs isKindOfClass:[NSArray class]]) return vcs;
    NSMutableArray *kept = [NSMutableArray array];
    for (UIViewController *vc in vcs)
        if (!max_isPrunedTab(vc)) [kept addObject:vc];
    if (kept.count != vcs.count)
        maxlog(@"prune: dropped %lu tab(s) from the tab bar",
               (unsigned long)(vcs.count - kept.count));
    return kept;
}

static void hook_setViewControllers(id self, SEL _cmd, NSArray *vcs) {
    vcs = max_filterTabVCs(vcs);
    if (orig_setViewControllers)
        ((void(*)(id,SEL,id))orig_setViewControllers)(self, _cmd, vcs);
}

static void hook_setViewControllersAnimated(id self, SEL _cmd, NSArray *vcs, BOOL animated) {
    vcs = max_filterTabVCs(vcs);
    if (orig_setViewControllersAnimated)
        ((void(*)(id,SEL,id,BOOL))orig_setViewControllersAnimated)(self, _cmd, vcs, animated);
    else if (orig_setViewControllers)
        ((void(*)(id,SEL,id))orig_setViewControllers)(self, _cmd, vcs);
}

static void max_installFeaturePruner(void) {
    struct {
        const char *cls;
        const char *sel;
        IMP hook;
    } hooks[] = {
        { "_TtC23OKMAppMessengerProtocol18OMPMSConfigStorage", "storiesEnabled",
          (IMP)max_hookBoolNo },
        { "OKMRouter", "_openDigitalIdTabWithReload:cancelSignal:completion:",
          (IMP)max_hookVoid3 },
        { "OKMRouter", "showWebAppListScreenWithWebAppSettings:",
          (IMP)max_hookVoid1 },
        { "OKMRouter", "openCreateChannel", (IMP)max_hookVoid0 },
        { "_TtC13ContactListUI26ContactPickerClosureRouter", "openCreateChannel",
          (IMP)max_hookVoid0 },
        { "_TtC13ContactListUI13WeakRefRouter", "openCreateChannel",
          (IMP)max_hookVoid0 },
        // v12.1: settings router blocks (Devices/Folders/Invite/Cache) were
        // REMOVED at the user's request — those tabs work normally again.
        // Only the super-app junk stays dead: Digital ID, mini-apps, channels.
        // v11.1: KILL THE TRACKERS AT RUNTIME. The static binary patches
        // (build_mods_v6.py) already neuter setup, but belt-and-suspenders:
        // even if anything re-initializes MyTracker, it can never send.
        // (nil-returning hooks are used where the dump suggests an object
        // return — nil is safe for void callers too)
        { "MRMainTracker", "trackEventWithName:eventParams:", (IMP)max_hookIdRetNil },
        { "MRMainTracker", "trackLoginEvent:withVkConnectId:params:", (IMP)max_hookIdRetNil },
        { "MRMainTracker", "trackRegistrationEvent:withVkConnectId:params:", (IMP)max_hookIdRetNil },
        { "MRMainTracker", "trackInviteEventWithParams:", (IMP)max_hookVoid0 },
        { "MRMainTracker", "trackDeeplinkURL:", (IMP)max_hookVoid1 },
        { "MRMainTracker", "flushWithCompletionBlock:", (IMP)max_hookVoid1 },
        { "MRMainTracker", "setupWithTrackerId:", (IMP)max_hookVoid1 },
        // v11.3 audit: MREventTracker is a SECOND tracker implementation
        // (launch/install/update events) that bypassed MRMainTracker entirely
        { "MREventTracker", "trackLaunchEvent", (IMP)max_hookVoid0 },
        { "MREventTracker", "trackInstallEvent:", (IMP)max_hookVoid1 },
        { "MREventTracker", "trackUpdateEvent:oldBuild:newVersion:newBuild:", (IMP)max_hookIdRetNil },
        { "MREventTracker", "trackCustomEvent:params:", (IMP)max_hookIdRetNil },
        { "MREventTracker", "trackDeeplinkEvent:clickId:", (IMP)max_hookIdRetNil },
                { "MREventTracker", "flushIfNeeded:", (IMP)max_hookVoid1 },
        // the actual network send of tracker events
        { "MRMyTrackerService", "sendEventData:completion:", (IMP)max_hookVoid2 },
        // v11.3 audit: OKMStatisticsService aggregates EVERYTHING (screens,
        // settings, stickers, video, search, webapps, qr, permissions...) and
        // ships it to the server — silence every didLog* entry point
        { "OKMStatisticsService", "webAppStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "webAppStatService:didLogBridgeEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "videoRateStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "videoMessagesStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "stickerStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "shareToMaxStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "settingsStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "qrAuthStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "messageActionsStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "mediaMessageTranscriptStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "permissionsStatService:didLogPermissionChange:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "permissionsStatService:didLogStatus:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "screensStatsService:didLogScreenWith:time:sessionId:didUpdateSessionId:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "logCallReviewEventWithCallReviewData:rating:reasons:", (IMP)max_hookVoid3 },
        { "OKMStatisticsService", "logFPSStat:", (IMP)max_hookVoid1 },
        { "OKMStatisticsService", "logMainThreadHangs:", (IMP)max_hookVoid1 },
        { "OKMStatisticsService", "logPlayerStatsEvent:", (IMP)max_hookVoid1 },
        { "OKMStatisticsService", "sendAudioStats:", (IMP)max_hookVoid1 },
        { "OKMStatisticsService", "sendInfo:", (IMP)max_hookVoid1 },
        { "OKMStatisticsService", "logNetworkEntryWithType:command:responseTime:bytesSent:bytesReceived:error:retry:value:contents:", (IMP)max_hookIdRetNil },
        // v12.1 audit: the remaining didLog* entry points
        { "OKMStatisticsService", "inviteFriendsStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "inlineButtonClickStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "informerBannerStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "messagePresenceStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "chatProfileActionsStatsService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "channelRecSysFolderStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "callsStatService:didLogEvent:params:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "bannerTrackService:didLogBannerEvent:params:screenType:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "service:didLogAppStartSpans:source:", (IMP)max_hookIdRetNil },
        { "OKMStatisticsService", "didLogTwiceSend", (IMP)max_hookVoid0 },
        // v11.3 audit: push notification stats (replies, opens by push, VoIP)
        { "OKMPushStatsService", "trackPushReply:", (IMP)max_hookVoid1 },
        { "OKMPushStatsService", "trackPushDoNotDisturb:", (IMP)max_hookVoid1 },
        { "OKMPushStatsService", "trackChatOpenByPush:", (IMP)max_hookVoid1 },
        { "OKMPushStatsService", "trackChatURLByPush:", (IMP)max_hookVoid1 },
        { "OKMPushStatsService", "trackReceiveVoIPPush:receiveTime:", (IMP)max_hookIdRetNil },
        // message-view stats the server doesn't need
        { "OKMChatHandler", "sendStatsForMessageIds:", (IMP)max_hookIdRetNil },
        { "OKMChatHandler", "sendStatsForMessageIds:chatId:", (IMP)max_hookVoid2 },
        // tracker location writer: never write any location
        { "MRLocationInfoWriter", "writeImpl:auxiliaryProtoData:", (IMP)max_hookIdRetNil },
        // master switch off even if config storage is re-read at runtime
        { "_TtC23OKMAppMessengerProtocol18OMPMSConfigStorage", "myTrackerEnabled",
          (IMP)max_hookBoolNo },
        // v11.1: CALLS OFF — chat-only messenger
        { "OKMUserSettings", "showCallsTab", (IMP)max_hookBoolNo },
        // v11.4: MICROPHONE & CAMERA OFF COMPLETELY. The Info.plist usage
        // keys are removed at repack time (iOS auto-denies any access), and
        // these hooks kill the record/capture entry points so nothing even
        // tries to start. Voice messages are simply unavailable.
        { "OKMAudioRecorderService",
          "audioRecorderStartWithMaxDuration:bitrate:sampleRate:callbackKey:",
          (IMP)max_hookIdRetNil },
        { "_TtC22OMAudioRecorderService22OMAudioRecorderService",
          "audioRecorderStartWithMaxDuration:bitrate:sampleRate:callbackKey:",
          (IMP)max_hookVoid0 },
        { "OKMAudioService",
          "audioRecorderStartWithMaxDuration:bitrate:sampleRate:callbackKey:",
          (IMP)max_hookIdRetNil },
        { "OKMAudioService",
          "_startRecordingMaxDuration:callbackKey:completion:error:",
          (IMP)max_hookIdRetNil },
        { "_TtC20OMLegacyChatSwiftKit11OMChatInput",
          "startRecordingWithIsLongTap:", (IMP)max_hookVoid0 },
        { "OMChatSendoutViewModel", "startRecording", (IMP)max_hookVoid0 },
        { "OKMAudioRecorderService", "isRecordingAudio", (IMP)max_hookBoolRetNo },
        { "OKMAudioService", "isRecordingAudio", (IMP)max_hookBoolRetNo },
        // QR scanner camera (the only direct camera consumer left)
        { "_TtC8OMCamera15OMCameraFactory",
          "makeQRCodeScannerCameraWithDescriptionMessage:isTorchEnabled:screenStatsType:screenStatsEventSource:scannerType:delegate:requestPermissionInSettingsAction:openGalleryAction:detectedValueHandler:",
          (IMP)max_hookIdRetNil },
    };
    for (NSUInteger i = 0; i < sizeof(hooks)/sizeof(hooks[0]); i++) {
        Class cls = objc_getClass(hooks[i].cls);
        if (!cls) {
            maxlog(@"prune: class not found: %s", hooks[i].cls);
            continue;
        }
        SEL sel = sel_registerName(hooks[i].sel);
        if (!max_replaceMethod(cls, sel, hooks[i].hook)) {
            maxlog(@"prune: method not found: %s -> %s", hooks[i].cls, hooks[i].sel);
            continue;
        }
        maxlog(@"prune: blocked %s -> %s", hooks[i].cls, hooks[i].sel);
    }

    // Digital ID tab: filter it out whenever the app rebuilds the tab bar.
    // Hook both 1-arg and 2-arg setters — UIKit's animated path is the one
    // MAX actually uses after login / feature flags.
    Class tbc = objc_getClass("_TtC7OMUIKit16TabBarController");
    if (tbc) {
        orig_setViewControllers = swizzle(tbc, @selector(setViewControllers:),
                                          (IMP)hook_setViewControllers);
        orig_setViewControllersAnimated = swizzle(tbc,
            @selector(setViewControllers:animated:),
            (IMP)hook_setViewControllersAnimated);
        maxlog(@"prune: tab-bar filter 1-arg %@, 2-arg %@",
               orig_setViewControllers ? @"OK" : @"MISS",
               orig_setViewControllersAnimated ? @"OK" : @"MISS");
    }
}

// ============================================================================
#pragma mark - Settings screen pruning
//
// OKMActionsViewModel drives the settings screens: setSections: receives
// OKMActionsSection objects (title/footer/actions), each action an
// OKMActionCellViewModel with a plain `title` property. Filter out the
// junk rows the user selected: the Госуслуги login block, Invite Friends,
// Devices, Folders, Power and Data Saving, Storage, Потужно для бизнеса.
// ============================================================================

static IMP orig_setSections = NULL;

static BOOL max_titleIsPruned(NSString *title) {
    if (title.length == 0) return NO;
    NSArray<NSString *> *pruned = @[
        @"Госуслуг",           // Госуслуги block + Войти по Госуслугам
        @"Gosuslugi",          // latin server variant
        @"Вернуть уведомления",
        @"Единый вход",
        @"Пригласить друзей",  // Invite Friends
        @"Invite Friends",
        @"Устройства",         // Devices
        @"Папки",              // Folders
        @"Экономия батареи",   // Power and Data Saving
        @"Память",             // Storage
        @"для бизнеса",        // Потужно для бизнеса
        @"Мини-приложения",    // Web apps leftovers
    ];
    for (NSString *bad in pruned)
        if ([title rangeOfString:bad options:NSCaseInsensitiveSearch].location != NSNotFound)
            return YES;
    return NO;
}

static int g_setSectionsLogBudget = 12;   // log titles for the first N calls

static void hook_setSections(id self, SEL _cmd, NSArray *sections) {
    @try {
        if ([sections isKindOfClass:[NSArray class]] && sections.count > 0) {
            if (g_setSectionsLogBudget > 0) {
                g_setSectionsLogBudget--;
                NSString *cls = NSStringFromClass(object_getClass(self));
                for (id section in sections) {
                    NSString *stitle = [section respondsToSelector:@selector(title)]
                        ? [section title] : nil;
                    NSMutableString *rows = [NSMutableString string];
                    if ([section respondsToSelector:@selector(actions)]) {
                        NSArray *acts =
                            ((id(*)(id,SEL))objc_msgSend)(section, @selector(actions));
                        if ([acts isKindOfClass:[NSArray class]]) {
                            NSMutableArray *t = [NSMutableArray array];
                            for (id a in acts)
                                if ([a respondsToSelector:@selector(title)])
                                    [t addObject:([a title] ?: @"-")];
                            [rows appendFormat:@" | %@", [t componentsJoinedByString:@", "]];
                        }
                    }
                    maxlog(@"sections-dump [%@] section '%@'%@", cls,
                           stitle ?: @"-", rows);
                }
            }
            NSMutableArray *kept = [NSMutableArray array];
            NSUInteger droppedSections = 0, droppedActions = 0;
            for (id section in sections) {
                NSString *stitle = [section respondsToSelector:@selector(title)]
                    ? [section title] : nil;
                if (max_titleIsPruned(stitle)) {
                    droppedSections++;
                    continue;
                }
                if ([section respondsToSelector:@selector(actions)]) {
                    NSArray *actions =
                        ((id(*)(id,SEL))objc_msgSend)(section, @selector(actions));
                    if ([actions isKindOfClass:[NSArray class]] && actions.count > 0) {
                        NSMutableArray *keptActions = [NSMutableArray array];
                        for (id action in actions) {
                            NSString *atitle = [action respondsToSelector:@selector(title)]
                                ? [action title] : nil;
                            if (max_titleIsPruned(atitle)) {
                                droppedActions++;
                                continue;
                            }
                            [keptActions addObject:action];
                        }
                        if (keptActions.count != actions.count) {
                            ((void(*)(id,SEL,id))objc_msgSend)(
                                section, @selector(setActions:), keptActions);
                        }
                    }
                }
                [kept addObject:section];
            }
            if (droppedSections || droppedActions) {
                maxlog(@"settings-prune: dropped %lu section(s), %lu row(s)",
                       (unsigned long)droppedSections, (unsigned long)droppedActions);
                sections = kept;
            }
        }
    } @catch (NSException *e) {
        maxlog(@"settings-prune: filter error %@", e);
    }
    if (orig_setSections)
        ((void(*)(id,SEL,id))orig_setSections)(self, _cmd, sections);
}

static void max_installSettingsPruner(void) {
    Class cls = objc_getClass("OKMActionsViewModel");
    if (!cls) {
        maxlog(@"settings-prune: OKMActionsViewModel not found");
        return;
    }
    orig_setSections = swizzle(cls, @selector(setSections:), (IMP)hook_setSections);
    maxlog(@"settings-prune: %@", orig_setSections ? @"installed" : @"swizzle failed");
}

// ============================================================================
#if 0  // v11.0: view-level settings pruning + layout surgery REMOVED (user decision: cut features, not rows)
#pragma mark - Settings junk: view-level pruning + title dump
//
// The settings screens are pure Swift (SettingsUI SourceModels) — no ObjC
// entry point to filter sections (OKMActionsViewModel is not used there:
// v6.9 log had zero sections-dump lines). Fallback that always works:
// when a SettingsUI view controller appears, walk its view tree, dump every
// label text to the log (diagnostics), and hide rows whose labels match the
// junk list. Hiding the label's ancestor UICollectionViewCell is enough —
// an empty cell renders as nothing.
// ============================================================================

static BOOL max_settingsTitleIsJunk(NSString *title) {
    if (title.length < 3) return NO;
    static NSArray<NSString *> *junk = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        junk = @[
            @"Госуслуг", @"Gosuslugi", @"Единый вход",
            @"Цифровой ID", @"Digital ID",   // settings row (router/tab already blocked)
            @"Вернуть уведомления",
            @"Пригласить друзей", @"Invite Friends",
            @"Устройства", @"Devices", @"Devices With", @"Sign in on new devices",
            @"Папк",                       // Папки/Папка
            @"Экономия батареи", @"Power and Data",
            @"Память", @"Storage",
            @"для бизнеса",
            @"Мини-приложения", @"Мини приложения",
        ];
    });
    for (NSString *bad in junk)
        if ([title rangeOfString:bad options:NSCaseInsensitiveSearch].location != NSNotFound)
            return YES;
    return NO;
}

static int g_settingsDumpBudget = 40;   // log the first N labels once

static NSString *max_labelText(UILabel *label);   // defined in the v10.5 section below

static void max_settingsPruneViews(UIView *view, int depth) {
    if (!view || depth > 10) return;

    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        NSString *text = max_labelText(label);
        if (text.length > 0 && g_settingsDumpBudget > 0) {
            g_settingsDumpBudget--;
            maxlog(@"labels-dump: '%@'", text);
        }
        if (max_settingsTitleIsJunk(text)) {
            // climb to the containing cell and collapse it
            UIView *cursor = label;
            for (int i = 0; i < 8 && cursor; i++) {
                if ([cursor isKindOfClass:[UICollectionViewCell class]] ||
                    [cursor isKindOfClass:[UITableViewCell class]]) {
                    maxlog(@"settings-hide: '%@'", text);
                    cursor.hidden = YES;
                    [UIView animateWithDuration:0.15 animations:^{
                        cursor.alpha = 0.0;
                    }];
                    // v10.4 diagnostics: which list type hosts the cell
                    UIView *p = cursor.superview;
                    while (p && ![p isKindOfClass:[UICollectionView class]]
                              && ![p isKindOfClass:[UITableView class]])
                        p = p.superview;
                    if (p) {
                        maxlog(@"settings-host: %@ layout=%@",
                               NSStringFromClass(p.class),
                               NSStringFromClass([p valueForKeyPath:
                                   @"collectionViewLayout.class"] ?: nil));
                    }
                    break;
                }
                cursor = cursor.superview;
            }
        }
    }
    // v10.6 diagnostics: the Gosuslugi block never shows up as a UILabel —
    // dump any CATextLayer strings too, so we can see its real text source
    if (g_settingsDumpBudget > 0 && [view isKindOfClass:objc_getClass("CATextLayer")]) {
        id s = [view valueForKeyPath:@"string"];
        if ([s isKindOfClass:[NSString class]] && ((NSString *)s).length > 1) {
            g_settingsDumpBudget--;
            maxlog(@"labels-dump[CATextLayer]: '%@'", s);
        }
    }
    for (UIView *sub in view.subviews)
        max_settingsPruneViews(sub, depth + 1);
}

// ---------------------------------------------------------------------------
// v10.4: collapse hidden rows so the remaining ones MOVE UP. Hiding a cell's
// content still reserves layout space (the user saw empty gaps). For self-
// sizing collection cells, zeroing the preferred layout attributes makes the
// row collapse to zero height entirely.
// SAFETY: only applied to cells whose responder chain contains a view
// controller with "Settings" in its class name — a chat message containing
// e.g. "папка" must never collapse a bubble (lesson of the v7.5 mass-dim).
// ---------------------------------------------------------------------------

static BOOL max_cellInSettingsScreen(UIResponder *responder) {
    UIResponder *r = responder;
    for (int i = 0; i < 25 && r; i++) {
        if ([r isKindOfClass:[UIViewController class]]) {
            NSString *cls = NSStringFromClass(r.class);
            if ([cls rangeOfString:@"Settings" options:NSCaseInsensitiveSearch].location != NSNotFound)
                return YES;
        }
        r = r.nextResponder;
    }
    return NO;
}

// label text that the junk check sees: plain text OR attributedText
// (the Gosuslugi block was invisible to the filter because its labels use
// attributed strings — label.text is nil there)
static NSString *max_labelText(UILabel *label) {
    if (label.text.length > 0) return label.text;
    if (label.attributedText.length > 0)
        return [label.attributedText string];
    return nil;
}

static BOOL max_viewContainsJunkLabel(UIView *view, int depth) {
    if (!view || depth > 6) return NO;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)view;
        if (max_settingsTitleIsJunk(max_labelText(l))) return YES;
    }
    for (UIView *sub in view.subviews)
        if (max_viewContainsJunkLabel(sub, depth + 1)) return YES;
    return NO;
}

static IMP orig_preferredLayoutAttrs = NULL;

static id hook_preferredLayoutAttrs(id self, SEL _cmd, id attrs) {
    id result = ((id(*)(id,SEL,id))orig_preferredLayoutAttrs)(self, _cmd, attrs);
    if (!result) return result;
    @try {
        if (max_cellInSettingsScreen((UIResponder *)self) &&
            max_viewContainsJunkLabel((UIView *)self, 0)) {
            ((void(*)(id,SEL,CGRect))objc_msgSend)
                (result, sel_registerName("setFrame:"), CGRectZero);
            ((void(*)(id,SEL,BOOL))objc_msgSend)
                (self, sel_registerName("setHidden:"), YES);
        }
    } @catch (NSException *e) {
        // never let the collapse hook kill layout
    }
    return result;
}

static void max_installRowCollapseHook(void) {
    Method m = class_getInstanceMethod([UICollectionViewCell class],
        @selector(preferredLayoutAttributesFittingAttributes:));
    if (m) {
        orig_preferredLayoutAttrs = method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_preferredLayoutAttrs);
        maxlog(@"settings-collapse: preferredLayoutAttributesFittingAttributes hooked");
    } else {
        maxlog(@"settings-collapse: hook method not found");
    }
}

// ---------------------------------------------------------------------------
// v10.5: filter junk cells at the LAYOUT level. v10.4's zero-size approach
// did nothing — this collection view's layout is not self-sizing, cell sizes
// come from the layout itself. Hook layoutAttributesForElementsInRect: and
// drop the attributes of junk cells from the returned array entirely: the
// cell leaves the flow, the rows below MOVE UP.
// SAFETY: only when the layout's collection view sits on a Settings screen.
// ---------------------------------------------------------------------------

static BOOL max_layoutOnSettingsScreen(UICollectionViewLayout *layout) {
    @try {
        UICollectionView *cv = ((UICollectionView *(*)(id,SEL))objc_msgSend)
            (layout, sel_registerName("collectionView"));
        return cv && max_cellInSettingsScreen((UIResponder *)cv);
    } @catch (NSException *e) {
        return NO;
    }
}

static NSMutableDictionary *g_layoutOrigMap = nil;   // Class -> NSValue(IMP)

static CGSize hook_collectionViewContentSize(id self, SEL _cmd);   // below

static id hook_layoutAttrsForElements(id self, SEL _cmd, CGRect rect) {
    NSArray *result = nil;
    @synchronized (g_layoutOrigMap) {
        NSValue *v = g_layoutOrigMap[NSStringFromClass(object_getClass(self))];
        if (!v) {
            // unknown class: call through the base implementation pointer
            // stored under the base-class key
            v = g_layoutOrigMap[NSStringFromClass([UICollectionViewLayout class])];
        }
        IMP orig = v ? (IMP)v.pointerValue : NULL;
        if (orig) result = ((id(*)(id,SEL,CGRect))orig)(self, _cmd, rect);
    }
    if (![result isKindOfClass:[NSArray class]] || result.count == 0)
        return result;
    if (!max_layoutOnSettingsScreen((UICollectionViewLayout *)self))
        return result;
    @try {
        // v10.6: match junk by visible-cell FRAMES — cellForItemAtIndexPath
        // returns nil mid-layout, which is why v10.5 never dropped anything
        UICollectionView *cv = ((UICollectionView *(*)(id,SEL))objc_msgSend)
            (self, sel_registerName("collectionView"));
        if (!cv) return result;
        // v10.8: dropping attributes left GAPS — in a compositional layout
        // each cell's position is computed independently, so removing one
        // attr doesn't move the others. Instead: SHIFT every attribute that
        // sits below a junk cell up by the junk height, and squash the junk
        // attribute itself to zero height. Rows physically move up.
        NSMutableArray *junkRects = [NSMutableArray array];
        for (UICollectionViewCell *cell in cv.visibleCells)
            if (max_viewContainsJunkLabel(cell, 0))
                [junkRects addObject:[NSValue valueWithCGRect:cell.frame]];
        if (junkRects.count == 0) return result;
        // sort junk rects top-to-bottom for deterministic shifting
        [junkRects sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
            CGFloat ay = a.CGRectValue.origin.y, by = b.CGRectValue.origin.y;
            return ay < by ? NSOrderedAscending : (ay > by ? NSOrderedDescending : NSOrderedSame);
        }];
        NSUInteger squashed = 0;
        for (UICollectionViewLayoutAttributes *attr in result) {
            CGRect f = attr.frame;
            BOOL isJunk = NO;
            CGFloat shift = 0.0;
            for (NSValue *v in junkRects) {
                CGRect j = v.CGRectValue;
                if (CGRectEqualToRect(j, f)) { isJunk = YES; continue; }
                // attribute sits fully BELOW this junk row -> shift it up
                if (f.origin.y >= j.origin.y + j.size.height - 1.0)
                    shift += j.size.height;
            }
            if (isJunk) {
                squashed++;
                attr.frame = CGRectMake(f.origin.x, f.origin.y - shift,
                                        f.size.width, 0.0);
            } else if (shift > 0.0) {
                attr.frame = CGRectMake(f.origin.x, f.origin.y - shift,
                                        f.size.width, f.size.height);
            }
        }
        if (squashed > 0)
            maxlog(@"settings-collapse: squashed %lu junk row(s), shifted the rest up",
                   (unsigned long)squashed);
    } @catch (NSException *e) {
        // fall through with the original array
    }
    return result;
}

static void max_layoutHookClass(Class c) {
    Method m = class_getInstanceMethod(c,
        @selector(layoutAttributesForElementsInRect:));
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == (IMP)hook_layoutAttrsForElements) return;   // already hooked
    maxlog(@"settings-collapse: hooked %@", NSStringFromClass(c));
    if (!g_layoutOrigMap) g_layoutOrigMap = [NSMutableDictionary new];
    @synchronized (g_layoutOrigMap) {
        g_layoutOrigMap[NSStringFromClass(c)] = [NSValue valueWithPointer:cur];
    }
    method_setImplementation(m, (IMP)hook_layoutAttrsForElements);

    // v10.8: also shrink the scrollable content size by the total junk
    // height, otherwise the shifted-up rows leave dead space at the bottom
    Method sz = class_getInstanceMethod(c, @selector(collectionViewContentSize));
    if (sz && method_getImplementation(sz) != (IMP)hook_collectionViewContentSize) {
        IMP curSz = method_getImplementation(sz);
        @synchronized (g_layoutOrigMap) {
            NSString *key = [@"size:" stringByAppendingString:NSStringFromClass(c)];
            g_layoutOrigMap[key] = [NSValue valueWithPointer:curSz];
        }
        method_setImplementation(sz, (IMP)hook_collectionViewContentSize);
    }
}

static CGSize hook_collectionViewContentSize(id self, SEL _cmd) {
    CGSize size = CGSizeZero;
    @synchronized (g_layoutOrigMap) {
        NSValue *v = g_layoutOrigMap[[@"size:" stringByAppendingString:
                                       NSStringFromClass(object_getClass(self))]];
        if (!v) v = g_layoutOrigMap[[@"size:" stringByAppendingString:
                                     NSStringFromClass([UICollectionViewLayout class])]];
        IMP orig = v ? (IMP)v.pointerValue : NULL;
        if (orig) size = ((CGSize(*)(id,SEL))orig)(self, _cmd);
    }
    if (!max_layoutOnSettingsScreen((UICollectionViewLayout *)self))
        return size;
    @try {
        UICollectionView *cv = ((UICollectionView *(*)(id,SEL))objc_msgSend)
            (self, sel_registerName("collectionView"));
        if (!cv) return size;
        CGFloat junkH = 0.0;
        for (UICollectionViewCell *cell in cv.visibleCells)
            if (max_viewContainsJunkLabel(cell, 0))
                junkH += cell.frame.size.height;
        if (junkH > 0.0 && size.height > junkH)
            size.height -= junkH;
    } @catch (NSException *e) {
    }
    return size;
}

static void max_installLayoutFilterHook(void) {
    // hook the base class, then every UICollectionViewLayout subclass that
    // has its OWN override (a subclass override would otherwise bypass us —
    // compositional layouts do override this method)
    max_layoutHookClass([UICollectionViewLayout class]);
    unsigned int n = 0;
    Class *classes = objc_copyClassList(&n);
    int hooked = 0;
    for (unsigned i = 0; i < n; i++) {
        Class c = classes[i];
        if (c == [UICollectionViewLayout class]) continue;
        Class s = class_getSuperclass(c);
        BOOL isDirectLayoutSubclass = NO;
        for (int d = 0; d < 8 && s; d++) {
            if (s == [UICollectionViewLayout class]) { isDirectLayoutSubclass = (d == 0); break; }
            s = class_getSuperclass(s);
        }
        if (!isDirectLayoutSubclass) continue;
        // only classes that DECLARE their own implementation
        unsigned int mc = 0;
        Method *ml = class_copyMethodList(c, &mc);
        BOOL declares = NO;
        for (unsigned j = 0; j < mc; j++)
            if (method_getName(ml[j]) == @selector(layoutAttributesForElementsInRect:))
                { declares = YES; break; }
        free(ml);
        if (!declares) continue;
        max_layoutHookClass(c);
        hooked++;
    }
    free(classes);
    maxlog(@"settings-collapse: %d layout subclass(es) hooked", hooked);
}

static void max_installSettingsViewPruner(void) {
    // v10.1: prune any SettingsUI screen that becomes visible — not just
    // window roots (settings open as pushed/ presenting controllers, so the
    // old root-only check never fired on them).
    maxlog(@"settings-view-pruner: window observer installed");

    static void (^pruneAll)(void);
    pruneAll = ^{
        @try {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (![w isKindOfClass:[UIWindow class]]) continue;
                UIViewController *top = w.rootViewController;
                if (!top) continue;   // status-bar/alert windows: no root yet
                // climb to the topmost presented controller
                while (top.presentedViewController) top = top.presentedViewController;
                // walk the whole presented stack + all children
                // v10.6: walk with a "descendant of Settings" flag — prune the
                // Settings VC itself AND everything below it in the child tree
                // (the Gosuslugi block may live in a child VC whose class name
                // does not contain "Settings"), but never anything outside it
                NSMutableArray *stack = [NSMutableArray array];
                if (top) [stack addObject:@[top, @NO]];
                while (stack.count) {
                    NSArray *entry = stack.lastObject;
                    [stack removeLastObject];
                    UIViewController *vc = entry[0];
                    BOOL underSettings = [entry[1] boolValue];
                    if (!vc) continue;
                    NSString *cls = NSStringFromClass(vc.class);
                    BOOL isSettings = [cls rangeOfString:@"Settings"
                            options:NSCaseInsensitiveSearch].location != NSNotFound;
                    if (isSettings || underSettings) {
                        if (isSettings)
                            maxlog(@"settings-screen: %@ visible — pruning", cls);
                        max_settingsPruneViews(vc.view, 0);
                        dispatch_after(
                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                            dispatch_get_main_queue(),
                            ^{ max_settingsPruneViews(vc.view, 0); });
                    }
                    for (UIViewController *child in vc.childViewControllers)
                        if (child) [stack addObject:@[child,
                            @(isSettings || underSettings)]];
                }
            }
        } @catch (NSException *e) {
            maxlog(@"settings-prune: window walk error %@", e);
        }
    };

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIWindowDidBecomeVisibleNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        UIWindow *w = note.object;
        if (![w isKindOfClass:[UIWindow class]]) return;
        pruneAll();
    }];

    // screens are usually pushed without a new window: re-prune every 5s
    // for the first 2 minutes (cheap tree walk; catches settings opened
    // after launch without a window event)
    static __weak void (^g_pruneTick)(int);
    void (^tick)(int) = ^(int remaining) {
        if (remaining <= 0) return;
        pruneAll();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ g_pruneTick(remaining - 1); });
    };
    g_pruneTick = tick;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ tick(24); });
}

// ============================================================================
#endif  // end removed settings-view machinery
#pragma mark - Ghost mode hook (switch-controlled)
//
// v12.3: dedicated orig IMPs. The old table lookup used object_getClass(self)
// which misses KVO / Swift subclasses, then returned nil even with the
// switch OFF — receipts never left. Now: one stored IMP per selector, and
// OFF always forwards. Defaults live in standardUserDefaults AND a cache
// so a missing key never silently blocks.
//   mod.read — don't send read receipts (markAsReadTo: / markReactionAsReadTo:)
// ============================================================================

// g_blockRead declared with crash-catcher globals (used by max_crashLog)

static BOOL max_modOn(NSString *key) {
    if ([key isEqualToString:@"mod.read"]) return g_blockRead;
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

static void max_setModRead(BOOL on) {
    g_blockRead = on;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:on forKey:@"mod.read"];
    [d synchronize];
}

static IMP g_origMarkAsRead = NULL;
static IMP g_origMarkReactionAsRead = NULL;

static id max_hook_read2(id self, SEL _cmd, id a, id b) {
    // FULL-LOG: every invocation, with class + args
    maxlog(@"ghost: IN %@ self=%@(%p) a=%@ b=%@ block=%d", NSStringFromSelector(_cmd), NSStringFromClass(object_getClass(self)), self, max_desc(a), max_desc(b), (int)g_blockRead);
    if (g_blockRead) {
        maxlog(@"ghost: DROP %@ (mod.read ON)", NSStringFromSelector(_cmd));
        return nil;
    }
    IMP o = NULL;
    if (_cmd == sel_registerName("markAsReadTo:messageId:"))
        o = g_origMarkAsRead;
    else if (_cmd == sel_registerName("markReactionAsReadTo:messageId:"))
        o = g_origMarkReactionAsRead;
    if (!o) {
        maxlog(@"ghost: PASS %@ but orig IMP missing — calling super lookup",
               NSStringFromSelector(_cmd));
        Method m = class_getInstanceMethod(object_getClass(self), _cmd);
        if (m) {
            IMP cand = method_getImplementation(m);
            if (cand && cand != (IMP)max_hook_read2) o = cand;
        }
    }
    if (!o) {
        maxlog(@"ghost: WARNING no orig for %@ — cannot send receipt",
               NSStringFromSelector(_cmd));
        return nil;
    }
    return ((id(*)(id,SEL,id,id))o)(self, _cmd, a, b);
}

// ============================================================================
#if 0  // v10.0: keep-deleted / remote-delete machinery REMOVED (native deletes)
#pragma mark - Keep remote-deleted: neutralize the server "deleted" flag
//
// Final link in the chain. When the contact deletes a message, the server
// marks it deleted and the client receives an UPDATED message object with
// deleted=YES; the history then renders/removes it as deleted. The event
// hook (_handleDeletedMessages:inChatWithId:) covers one path, but the
// message-update path bypasses it. Hook the OKMMessage.deleted getter:
// with mod.del ON it always reports NO, so the UI keeps treating the
// message as alive no matter what the server says.
// ============================================================================

static IMP orig_messageDeletedGetter = NULL;

static BOOL hook_messageDeleted(id self, SEL _cmd) {
    if (max_modOn(@"mod.del")) return NO;   // "never deleted" for the UI
    return ((BOOL(*)(id,SEL))orig_messageDeletedGetter)(self, _cmd);
}

static NSMutableSet<NSString *> *g_markedDeleted = nil;
static NSMutableDictionary<NSString *, NSDate *> *g_approvedDeletePks = nil; // pk -> approval time
static NSTimeInterval const kMaxApprovalWindow = 30.0;   // deletion chains fan out (public -> private methods); an approval must survive them all

static BOOL max_pkIsApproved(NSString *s) {
    if (!g_approvedDeletePks.count) return NO;
    NSDate *t = g_approvedDeletePks[s];
    if (!t) return NO;
    if (-[t timeIntervalSinceNow] > kMaxApprovalWindow) {
        [g_approvedDeletePks removeObjectForKey:s];   // expired
        return NO;
    }
    return YES;
}

// ============================================================================
#pragma mark - Keep-deleted: block "delete for everyone" at the chat service
//
// The menu-level hook (_deleteMessage:context:) covers the message action,
// but the CONFIRMATION of "удалить у всех" goes straight to
// OKMChatService deleteMessagesWithPks:deleteForAll: (and the private
// variants) — that path bypassed the two-phase logic. Same rules here:
// 1st delete of a pk marks it (cell dims), 2nd delete of a marked pk
// really deletes. Mod.del OFF — normal behavior.
// ============================================================================

static IMP orig_deleteWithPks = NULL;
static IMP orig_deleteWithPks2 = NULL;
static IMP orig_deleteWithPksEnqueue = NULL;

__attribute__((unused))
static BOOL max_pksContainMarked(NSArray *pks) {
    if (![pks isKindOfClass:[NSArray class]]) return NO;
    for (id pk in pks) {
        NSString *s = [NSString stringWithFormat:@"%@", pk];
        if ([g_markedDeleted containsObject:s]) return YES;
    }
    return NO;
}

__attribute__((unused))
static NSArray *max_unmarkPks(NSArray *pks) {
    NSMutableArray *out = [NSMutableArray array];
    for (id pk in pks) {
        NSString *s = [NSString stringWithFormat:@"%@", pk];
        if (![g_markedDeleted containsObject:s]) [out addObject:pk];
        else [g_markedDeleted removeObject:s];
    }
    [[NSUserDefaults standardUserDefaults] setObject:[g_markedDeleted allObjects]
                                              forKey:@"mod.markedDeleted"];
    return out;
}

static void max_deletePksBlocked(NSArray *pks, SEL _cmd) {
    // two-phase: mark every FRESH pk (1st delete) and swallow the call;
    // approved pks are never re-marked (chain re-invocations)
    NSMutableArray *markedNow = [NSMutableArray array];
    for (id pk in (pks ?: @[])) {
        NSString *s = [NSString stringWithFormat:@"%@", pk];
        if (max_pkIsApproved(s)) continue;
        if (![g_markedDeleted containsObject:s]) {
            [g_markedDeleted addObject:s];
            [markedNow addObject:s];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:[g_markedDeleted allObjects]
                                              forKey:@"mod.markedDeleted"];
    maxlog(@"keep-deleted: delete-for-all blocked [%@] (sel %@)",
           [markedNow componentsJoinedByString:@","], NSStringFromSelector(_cmd));
}

// pk resolution: the menu hook stores "%@" of primaryKey; the service pks
// may arrive as numbers/strings — compare both string forms.
static BOOL max_pkInSet(id pk, NSSet<NSString *> *set) {
    if (!pk || !set.count) return NO;
    NSString *s = [NSString stringWithFormat:@"%@", pk];
    if ([set containsObject:s]) return YES;
    // numeric normalization (e.g. "123" vs " 123" or NSNumber prints)
    const char *c = s.UTF8String;
    if (c) {
        long long v = strtoll(c, NULL, 10);
        if (v != 0 || strcmp(c, "0") == 0) {
            NSString *n = [NSString stringWithFormat:@"%lld", v];
            if ([set containsObject:n]) return YES;
        }
    }
    return NO;
}

// Decision for a delete request with mod.del ON:
//   pk approved by the menu hook (2nd delete) -> let it through, consume
//   pk marked (path bypassed the menu hook)   -> let it through, unmark
//   fresh pk                                   -> block + mark (1st phase)
static BOOL max_deletePksShouldPass(NSArray *pks, BOOL consume) {
    (void)consume;   // approvals are windowed, never consumed on first use —
                     // the public method calls the private one internally
    BOOL anyApproved = NO, anyMarked = NO;
    for (id pk in (pks ?: @[])) {
        NSString *s = [NSString stringWithFormat:@"%@", pk];
        if (max_pkIsApproved(s)) { anyApproved = YES; continue; }
        if (max_pkInSet(pk, g_markedDeleted)) { anyMarked = YES; }
    }
    if (anyApproved) {
        return YES;                                // let the whole chain through
    }
    if (anyMarked) {
        // confirmed re-delete on a path that bypassed the menu hook
        for (id pk in (pks ?: @[])) {
            NSString *s = [NSString stringWithFormat:@"%@", pk];
            if (!max_pkIsApproved(s)) [g_markedDeleted removeObject:s];
        }
        [[NSUserDefaults standardUserDefaults] setObject:[g_markedDeleted allObjects]
                                                  forKey:@"mod.markedDeleted"];
        return YES;
    }
    return NO;
}

static void hook_deleteWithPks(id self, SEL _cmd, id pks, BOOL deleteForAll) {
    maxlog(@"delete-svc: %@ pks=%@ forAll=%d",
           NSStringFromSelector(_cmd),
           [pks isKindOfClass:[NSArray class]]
               ? [pks componentsJoinedByString:@","] : [NSString stringWithFormat:@"%@", pks],
           (int)deleteForAll);
    if (max_modOn(@"mod.del") && !max_deletePksShouldPass((NSArray *)pks, YES)) {
        max_deletePksBlocked((NSArray *)pks, _cmd);
        return;   // swallow: nothing leaves the device, nothing is removed
    }
    ((void(*)(id,SEL,id,BOOL))orig_deleteWithPks)(self, _cmd, pks, deleteForAll);
}

static void hook_deleteWithPks2(id self, SEL _cmd, id pks, BOOL deleteForAll, id complaint) {
    maxlog(@"delete-svc: %@ pks=%@ forAll=%d",
           NSStringFromSelector(_cmd),
           [pks isKindOfClass:[NSArray class]]
               ? [pks componentsJoinedByString:@","] : [NSString stringWithFormat:@"%@", pks],
           (int)deleteForAll);
    if (max_modOn(@"mod.del") && !max_deletePksShouldPass((NSArray *)pks, YES)) {
        max_deletePksBlocked((NSArray *)pks, _cmd);
        return;
    }
    ((void(*)(id,SEL,id,BOOL,id))orig_deleteWithPks2)(self, _cmd, pks, deleteForAll, complaint);
}

// The task that actually sends the delete command to the server — logs the
// fact of sending so the next log shows whether deletions reach the wire.
static IMP orig_sendDeleteCommand = NULL;

// pks whose delete command was already SENT to the server (persisted). A
// stuck DB task re-runs on every launch and re-sends the command for
// already-deleted messages; the server error response then crashes the app
// (crash loop). Re-sends are skipped entirely.
static NSString *const kSentPksKey = @"mod.serverSentPks";

static NSString *max_pkOfMessage(id m) {
    if (!m) return nil;
    SEL sel = sel_registerName("primaryKey");
    if ([m respondsToSelector:sel])
        return [NSString stringWithFormat:@"%@", ((id(*)(id,SEL))objc_msgSend)(m, sel)];
    return [NSString stringWithFormat:@"%@", m];
}

// v9.3: this method RETURNS a RACSignal the caller subscribes to
// (subscribeNext:error:completed:). The hook used to be void, so the caller
// subscribed to the garbage left in x0 (the task itself) and crashed with
// "unrecognized selector" on EVERY delete after the send — the send itself
// was fine. On SKIP we return an immediately-completing RACSignal so the
// stuck task finally finishes and is cleared from the persistent queue.
static id hook_sendDeleteCommand(id self, SEL _cmd, id messages) {
    NSArray *items = [messages isKindOfClass:[NSArray class]]
        ? messages : (messages ? @[messages] : @[]);

    NSMutableArray<NSString *> *pks = [NSMutableArray array];
    for (id m in items) {
        NSString *pk = max_pkOfMessage(m);
        if (pk) [pks addObject:pk];
    }
    maxlog(@"server-delete: _sendDeleteCommandForMessages: fired (%lu messages, pks=%@)",
           (unsigned long)items.count, [pks componentsJoinedByString:@","]);

    if (pks.count > 0 && max_modOn(@"mod.del")) {
        // idempotency: check which pks were already sent
        NSSet *sent = [NSSet setWithArray:
            [[NSUserDefaults standardUserDefaults] stringArrayForKey:kSentPksKey] ?: @[]];
        BOOL allSent = YES;
        for (NSString *pk in pks)
            if (![sent containsObject:pk]) { allSent = NO; break; }
        if (allSent && sent.count > 0) {
            // The server has nothing left to delete; re-sending gets an error
            // response whose handling crashes the app (stuck-task crash loop).
            maxlog(@"server-delete: SKIP - all pks already sent before (stuck task)");
            Class rac = objc_getClass("RACSignal");
            if (rac) {
                id empty = ((id(*)(id,SEL))objc_msgSend)(rac, sel_registerName("empty"));
                if (empty) return empty;   // completes instantly -> task finishes
            }
            return nil;
        }
    }

    id result = nil;
    @try {
        result = ((id(*)(id,SEL,id))orig_sendDeleteCommand)(self, _cmd, messages);
    } @catch (NSException *e) {
        maxlog(@"server-delete: EXCEPTION in send: %@ - swallowed", e);
        Class rac = objc_getClass("RACSignal");
        if (rac) {
            id empty = ((id(*)(id,SEL))objc_msgSend)(rac, sel_registerName("empty"));
            if (empty) return empty;
        }
        return nil;
    }

    // record what we just sent (best effort; only while mod.del is on)
    if (pks.count > 0 && max_modOn(@"mod.del")) {
        NSMutableArray *sent = [[[NSUserDefaults standardUserDefaults]
            stringArrayForKey:kSentPksKey] mutableCopy] ?: [NSMutableArray array];
        for (NSString *pk in pks)
            if (![sent containsObject:pk]) [sent addObject:pk];
        // keep the list bounded
        if (sent.count > 200) {
            NSIndexSet *keep = [NSIndexSet indexSetWithIndexesInRange:
                NSMakeRange(sent.count - 200, 200)];
            sent = [[sent objectsAtIndexes:keep] mutableCopy];
        }
        [[NSUserDefaults standardUserDefaults] setObject:sent forKey:kSentPksKey];
    }
    return result;
}

static IMP orig_enqueueTasks = NULL;
static IMP orig_taskPerformWork = NULL;

static void hook_enqueueTasks(id self, SEL _cmd, id pks, BOOL deleteForAll, id tasks) {
    maxlog(@"task-trace: enqueueTasks fired, tasks=%@ (pks=%@ forAll=%d)",
           [tasks isKindOfClass:[NSArray class]] ? @([tasks count])
               : [NSString stringWithFormat:@"%@", tasks],
           [pks isKindOfClass:[NSArray class]]
               ? [pks componentsJoinedByString:@","] : @"?", (int)deleteForAll);
    ((void(*)(id,SEL,id,BOOL,id))orig_enqueueTasks)(self, _cmd, pks, deleteForAll, tasks);
}

static id hook_taskPerformWork(id self, SEL _cmd) {
    maxlog(@"task-trace: OKMDeleteMessagesTask performWorkSignal fired");
    // v8.9: performWorkSignal RETURNS the work signal — must pass it through
    return ((id(*)(id,SEL))orig_taskPerformWork)(self, _cmd);
}

static IMP orig_taskSetup = NULL;
static IMP orig_taskPrecond = NULL;

static void hook_taskSetup(id self, SEL _cmd, id registry) {
    maxlog(@"task-trace: setupWithRegistry: %@ (%@)",
           NSStringFromClass([registry class]), registry);
    ((void(*)(id,SEL,id))orig_taskSetup)(self, _cmd, registry);
}

static id hook_taskPrecond(id self, SEL _cmd) {
    id result = ((id(*)(id,SEL))orig_taskPrecond)(self, _cmd);
    // v8.9: return the signal! The v8.4 trace hook was declared void and
    // dropped the return value — the queue received garbage instead of the
    // precondition signal and the app crashed right after task start.
    return result;
}

// ============================================================================
#pragma mark - OKMTasksService: full queue trace
//
// v8.7: the delete task registers (setupWithRegistry) but never runs.
// OKMTasksService is the executor: enqueueTasks:withDependencies: ->
// enqueueTask: -> _performTask:. Hook every link to see exactly where
// the chain breaks.
// ============================================================================

static IMP orig_svcEnqueueDeps = NULL;
static IMP orig_svcEnqueue = NULL;
static IMP orig_svcPerform = NULL;
static IMP orig_svcEphemeral = NULL;

static void hook_svcEnqueueDeps(id self, SEL _cmd, id tasks, id deps) {
    BOOL hasDeleteTask = NO;
    if ([tasks isKindOfClass:[NSArray class]]) {
        Class dtc = objc_getClass("OKMDeleteMessagesTask");
        for (id t in tasks) {
            if (dtc && [t isKindOfClass:dtc]) { hasDeleteTask = YES; break; }
        }
    }
    maxlog(@"queue: enqueueTasks:withDependencies: tasks=%@ deps=%@ deleteTask=%d",
           [tasks isKindOfClass:[NSArray class]] ? @([tasks count])
               : [NSString stringWithFormat:@"%@", tasks],
           [deps isKindOfClass:[NSArray class]] ? @([deps count])
               : [NSString stringWithFormat:@"%@", deps],
           (int)hasDeleteTask);
    if (hasDeleteTask && [deps isKindOfClass:[NSArray class]] && [deps count] > 0) {
        // v8.8 FIX: the delete task is enqueued with a dependency that never
        // releases it - the queue runs OKMComplainTask but never starts
        // OKMDeleteMessagesTask (confirmed with all mods OFF). Enqueue the
        // tasks WITHOUT dependencies so the queue can run them immediately.
        maxlog(@"queue: FIX - dropping %lu dep(s) so the delete task can run",
               (unsigned long)[deps count]);
        deps = nil;
    }
    ((void(*)(id,SEL,id,id))orig_svcEnqueueDeps)(self, _cmd, tasks, deps);
}

static void hook_svcEnqueue(id self, SEL _cmd, id task) {
    maxlog(@"queue: enqueueTask: %@",
           NSStringFromClass([task class]));
    ((void(*)(id,SEL,id))orig_svcEnqueue)(self, _cmd, task);
}

static void hook_svcPerform(id self, SEL _cmd, id task) {
    maxlog(@"queue: _performTask: START %@",
           NSStringFromClass([task class]));
    ((void(*)(id,SEL,id))orig_svcPerform)(self, _cmd, task);
    maxlog(@"queue: _performTask: END %@",
           NSStringFromClass([task class]));
}

static void hook_svcEphemeral(id self, SEL _cmd, id task) {
    maxlog(@"queue: performEphemeralTask: %@",
           NSStringFromClass([task class]));
    ((void(*)(id,SEL,id))orig_svcEphemeral)(self, _cmd, task);
}

static void max_installTasksServiceTrace(void) {
    Class svc = objc_getClass("OKMTasksService");
    if (!svc) {
        maxlog(@"queue: OKMTasksService class not found");
        return;
    }
    struct { const char *sel; IMP *orig; IMP hook; } hooks[] = {
        { "enqueueTasks:withDependencies:", &orig_svcEnqueueDeps,
          (IMP)hook_svcEnqueueDeps },
        { "enqueueTask:", &orig_svcEnqueue,
          (IMP)hook_svcEnqueue },
        { "_performTask:", &orig_svcPerform,
          (IMP)hook_svcPerform },
        { "performEphemeralTask:", &orig_svcEphemeral,
          (IMP)hook_svcEphemeral },
    };
    for (NSUInteger i = 0; i < sizeof(hooks)/sizeof(hooks[0]); i++) {
        SEL sel = sel_registerName(hooks[i].sel);
        Method m = class_getInstanceMethod(svc, sel);
        if (!m) {
            maxlog(@"queue: method not found: %s", hooks[i].sel);
            continue;
        }
        *hooks[i].orig = method_getImplementation(m);
        method_setImplementation(m, hooks[i].hook);
        maxlog(@"queue: hooked %s", hooks[i].sel);
    }
}

// ============================================================================
#pragma mark - Remote-delete path tracing (v9.4)
//
// The user reports remotely deleted messages now DISAPPEAR (v9.0 made the
// 2-arg _handleDeletedMessages handler native, and that selector turned out
// to live only on OKMPushCleanupHelper — push cleanup, not history). The
// real incoming-delete path in this build is:
//   OKMMessageDeleteListener._messagesDeleted:inChat:
//   OKMMessageDeleteListener._delayedMessagesDeleted:
//   OKMChatService.deleteLocallyMessagesWithIds:updateChat:
// and OKMMessage itself has NO "deleted" property — only "status"
// (setStatus:), so the server may also flag deletion via a status update.
// v9.4 = pure tracing (everything runs native, nothing is blocked): the next
// log tells us exactly which path removes the message, then v9.5 blocks it.
// ============================================================================

static IMP orig_messagesDeletedInChat = NULL;
static IMP orig_delayedMessagesDeleted = NULL;
static IMP orig_deleteLocallyIds = NULL;
static IMP orig_setMessageStatus = NULL;

static NSString *max_idsDesc(id ids) {
    if ([ids isKindOfClass:[NSArray class]])
        return [ids componentsJoinedByString:@","];
    return [NSString stringWithFormat:@"%@", ids];
}

// v9.6: dim the newest visible message cell. Remote-deleted messages can't be
// matched to a cell by pk (MessageCell holds no model), but a live incoming
// delete virtually always targets the last message on screen — so we mark the
// highest indexPath among visible ChatHistoryUI message cells for the dim
// module (same mod.markedIndexPaths list the two-phase delete uses).
static void max_dimNewestVisibleCell(void) {
    @try {
        UIWindow *key = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows)
            if (w.isKeyWindow) { key = w; break; }
        if (!key) return;

        NSIndexPath *best = nil;
        // simple recursive scan without blocks-capturing-themselves
        NSMutableArray *stack = [NSMutableArray arrayWithObject:key];
        while (stack.count) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if ([v isKindOfClass:[UICollectionView class]]) {
                UICollectionView *cv = (UICollectionView *)v;
                for (UICollectionViewCell *cell in cv.visibleCells) {
                    NSString *cn = NSStringFromClass(cell.class);
                    if (![cn containsString:@"MessageCell"]) continue;
                    NSIndexPath *ip = [cv indexPathForCell:cell];
                    if (!ip) continue;
                    if (!best || ip.item > best.item) best = ip;
                }
            }
            [stack addObjectsFromArray:v.subviews];
        }
        if (!best) return;

        NSString *ipKey = [NSString stringWithFormat:@"%ld-%ld",
                           (long)best.section, (long)best.item];
        NSMutableArray *ips = [[[NSUserDefaults standardUserDefaults]
            stringArrayForKey:@"mod.markedIndexPaths"] mutableCopy]
            ?: [NSMutableArray array];
        if (![ips containsObject:ipKey]) {
            [ips addObject:ipKey];
            [[NSUserDefaults standardUserDefaults] setObject:ips
                                                      forKey:@"mod.markedIndexPaths"];
        }
        maxlog(@"REMOTE-DEL: dim newest visible message cell at %@", ipKey);
    } @catch (NSException *e) {
        maxlog(@"REMOTE-DEL: dim helper exception: %@", e);
    }
}

static void hook_messagesDeletedInChat(id self, SEL _cmd, id a, id b) {
    // v9.5: this is the INCOMING remote-delete event (a contact deleted the
    // message). With mod.del ON we swallow it entirely: the message keeps its
    // current status, stays in the DB and in the history, and we mark it for
    // dimming like our own two-phase deletes. Own-delete confirmations are
    // never routed here (own path goes through the approved delete-svc chain).
    if (max_modOn(@"mod.del")) {
        maxlog(@"REMOTE-DEL: _messagesDeleted:inChat: SUPPRESSED ids=%@ chat=%@ (keeping message)",
               max_idsDesc(a), b);
        // v9.6: remember each kept message by pk (chatPk-msgId) and dim the
        // newest visible cell in the open chat — a live remote delete almost
        // always hits the last message(s) on screen.
        NSString *chatPk = nil;
        SEL pkSel = sel_registerName("primaryKey");
        if (b && [b respondsToSelector:pkSel])
            chatPk = [NSString stringWithFormat:@"%@",
                ((id(*)(id,SEL))objc_msgSend)(b, pkSel)];
        NSArray *msgIds = [a isKindOfClass:[NSArray class]] ? (NSArray *)a : (a ? @[a] : @[]);
        for (id mid in msgIds) {
            NSString *pk = [NSString stringWithFormat:@"%@-%@", chatPk ?: @"", mid];
            if (g_markedDeleted && ![g_markedDeleted containsObject:pk]) {
                [g_markedDeleted addObject:pk];
                [[NSUserDefaults standardUserDefaults]
                    setObject:[g_markedDeleted allObjects] forKey:@"mod.markedDeleted"];
            }
            maxlog(@"REMOTE-DEL: kept message pk=%@ — dimming", pk);
        }
        max_dimNewestVisibleCell();
        return;
    }
    maxlog(@"REMOTE-DEL: OKMMessageDeleteListener._messagesDeleted:inChat: ids=%@ chat=%@",
           max_idsDesc(a), b);
    ((void(*)(id,SEL,id,id))orig_messagesDeletedInChat)(self, _cmd, a, b);
}

static void hook_delayedMessagesDeleted(id self, SEL _cmd, id a) {
    maxlog(@"REMOTE-DEL: OKMMessageDeleteListener._delayedMessagesDeleted: %@",
           max_idsDesc(a));
    ((void(*)(id,SEL,id))orig_delayedMessagesDeleted)(self, _cmd, a);
}

static void hook_deleteLocallyIds(id self, SEL _cmd, id ids, BOOL updateChat) {
    maxlog(@"REMOTE-DEL: OKMChatService.deleteLocallyMessagesWithIds:updateChat: ids=%@ updateChat=%d",
           max_idsDesc(ids), (int)updateChat);
    ((void(*)(id,SEL,id,BOOL))orig_deleteLocallyIds)(self, _cmd, ids, updateChat);
}

static void hook_setMessageStatus(id self, SEL _cmd, long long status) {
    // v9.5: deletion arrives as status 2 (confirmed by trace: every remote
    // delete event is immediately followed by setStatus:2 on that message,
    // and deleteLocallyMessagesWithIds: is never called).
    // v9.6 rules for status 2 with mod.del ON:
    //   pk approved (own two-phase delete in flight) -> allow
    //   pk in mod.serverSentPks (own PREVIOUSLY deleted-for-all) -> allow:
    //     the server resends status 2 on every history sync, and blocking it
    //     resurrected the user's own long-deleted messages
    //   anything else (incoming remote delete) -> block + dim
    if (status == 2 && max_modOn(@"mod.del")) {
        NSString *pk = max_pkOfMessage(self);
        if (max_pkIsApproved(pk)) {
            maxlog(@"REMOTE-DEL: setStatus: 2 allowed (own-delete approval active, pk=%@)", pk);
        } else if (pk) {
            NSArray *sent = [[NSUserDefaults standardUserDefaults]
                stringArrayForKey:kSentPksKey] ?: @[];
            if ([sent containsObject:pk]) {
                maxlog(@"REMOTE-DEL: setStatus: 2 allowed (own message deleted before, pk=%@)", pk);
            } else {
                if (g_markedDeleted && ![g_markedDeleted containsObject:pk]) {
                    [g_markedDeleted addObject:pk];
                    [[NSUserDefaults standardUserDefaults]
                        setObject:[g_markedDeleted allObjects] forKey:@"mod.markedDeleted"];
                }
                maxlog(@"REMOTE-DEL: setStatus: 2 BLOCKED (pk=%@) — message stays visible", pk);
                max_dimNewestVisibleCell();
                ((void(*)(id,SEL,long long))orig_setMessageStatus)(self, _cmd, 0);
                return;
            }
        }
        ((void(*)(id,SEL,long long))orig_setMessageStatus)(self, _cmd, status);
        return;
    }
    ((void(*)(id,SEL,long long))orig_setMessageStatus)(self, _cmd, status);
}

static void max_installRemoteDeleteTrace(void) {
    Class listener = objc_getClass("OKMMessageDeleteListener");
    if (listener) {
        struct { SEL sel; IMP *orig; IMP hook; } hooks[] = {
            { @selector(_messagesDeleted:inChat:),
              &orig_messagesDeletedInChat, (IMP)hook_messagesDeletedInChat },
            { @selector(_delayedMessagesDeleted:),
              &orig_delayedMessagesDeleted, (IMP)hook_delayedMessagesDeleted },
        };
        for (NSUInteger i = 0; i < sizeof(hooks)/sizeof(hooks[0]); i++) {
            Method m = class_getInstanceMethod(listener, hooks[i].sel);
            if (!m) {
                maxlog(@"REMOTE-DEL: listener method not found: %@",
                       NSStringFromSelector(hooks[i].sel));
                continue;
            }
            *hooks[i].orig = method_getImplementation(m);
            method_setImplementation(m, hooks[i].hook);
            maxlog(@"REMOTE-DEL: trace hook on OKMMessageDeleteListener -> %@",
                   NSStringFromSelector(hooks[i].sel));
        }
    } else {
        maxlog(@"REMOTE-DEL: OKMMessageDeleteListener class not found");
    }

    Class svc = objc_getClass("OKMChatService");
    if (svc) {
        Method m = class_getInstanceMethod(svc,
            @selector(deleteLocallyMessagesWithIds:updateChat:));
        if (m) {
            orig_deleteLocallyIds = method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_deleteLocallyIds);
            maxlog(@"REMOTE-DEL: trace hook on OKMChatService -> deleteLocallyMessagesWithIds:updateChat:");
        } else {
            maxlog(@"REMOTE-DEL: deleteLocallyMessagesWithIds not found");
        }
    }

    Class msg = objc_getClass("OKMMessage");
    if (msg) {
        Method m = class_getInstanceMethod(msg, @selector(setStatus:));
        if (m) {
            orig_setMessageStatus = method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_setMessageStatus);
            maxlog(@"REMOTE-DEL: trace hook on OKMMessage -> setStatus:");
        } else {
            maxlog(@"REMOTE-DEL: OKMMessage.setStatus: not found");
        }
    }
}

static void max_installDeleteForAllHook(void) {
    {
        Class svc = objc_getClass("OKMChatService");
        if (svc) {
            Method m = class_getInstanceMethod(svc,
                @selector(_deleteMessagesWithPks:deleteForAll:enqueueTasks:));
            if (m) {
                orig_enqueueTasks = method_getImplementation(m);
                method_setImplementation(m, (IMP)hook_enqueueTasks);
                maxlog(@"keep-deleted: enqueueTasks trace hook installed");
            } else {
                maxlog(@"keep-deleted: enqueueTasks method NOT found");
            }
        }
    }
    {
        Class task = objc_getClass("OKMDeleteMessagesTask");
        if (task) {
            Method m = class_getInstanceMethod(task,
                @selector(_sendDeleteCommandForMessages:));
            if (m) {
                orig_sendDeleteCommand = method_getImplementation(m);
                method_setImplementation(m, (IMP)hook_sendDeleteCommand);
                maxlog(@"keep-deleted: server-delete command hook installed");
            }
            Method pw = class_getInstanceMethod(task, @selector(performWorkSignal));
            if (pw) {
                orig_taskPerformWork = method_getImplementation(pw);
                method_setImplementation(pw, (IMP)hook_taskPerformWork);
                maxlog(@"keep-deleted: task performWork trace hook installed");
            }
            Method su = class_getInstanceMethod(task, @selector(setupWithRegistry:));
            if (su) {
                orig_taskSetup = method_getImplementation(su);
                method_setImplementation(su, (IMP)hook_taskSetup);
                maxlog(@"keep-deleted: task setup trace hook installed");
            }
            Method pc = class_getInstanceMethod(task, @selector(preConditionSignals));
            if (pc) {
                orig_taskPrecond = method_getImplementation(pc);
                method_setImplementation(pc, (IMP)hook_taskPrecond);
                maxlog(@"keep-deleted: task precondition trace hook installed");
            }
        }
    }

    Class cls = objc_getClass("OKMChatService");
    if (!cls) {
        maxlog(@"keep-deleted: OKMChatService not found");
        return;
    }
    struct { SEL sel; IMP *orig; IMP hook; int kind; } hooks[] = {
        { @selector(deleteMessagesWithPks:deleteForAll:),
          &orig_deleteWithPks, (IMP)hook_deleteWithPks, 0 },
        { @selector(_deleteMessagesWithPks:deleteForAll:withLegacyComplaint:),
          &orig_deleteWithPks2, (IMP)hook_deleteWithPks2, 1 },
        { @selector(_deleteMessagesWithPks:deleteForAll:withComplaint:),
          &orig_deleteWithPks2, (IMP)hook_deleteWithPks2, 1 },
    };
    for (NSUInteger i = 0; i < sizeof(hooks)/sizeof(hooks[0]); i++) {
        Method m = class_getInstanceMethod(cls, hooks[i].sel);
        if (!m) {
            maxlog(@"keep-deleted: method not found: %@",
                   NSStringFromSelector(hooks[i].sel));
            continue;
        }
        *hooks[i].orig = method_getImplementation(m);
        method_setImplementation(m, hooks[i].hook);
        maxlog(@"keep-deleted: hooked %@",
               NSStringFromSelector(hooks[i].sel));
    }
}

static void max_installDeletedFlagHook(void) {
    Class cls = objc_getClass("OKMMessage");
    if (!cls) {
        maxlog(@"keep-deleted: OKMMessage class not found");
        return;
    }
    Method m = class_getInstanceMethod(cls, @selector(deleted));
    if (!m) {
        maxlog(@"keep-deleted: OKMMessage.deleted not found");
        return;
    }
    orig_messageDeletedGetter = method_getImplementation(m);
    method_setImplementation(m, (IMP)hook_messageDeleted);
    maxlog(@"keep-deleted: OKMMessage.deleted getter hooked");
}

#endif  // end removed block 1 (flag/forAll hooks)
static int max_hookOwnSel(Class cls, SEL sel, IMP hook, IMP *outOrig) {
    if (!cls) return 0;
    Method own = max_ownInstanceMethod(cls, sel);
    if (!own) return 0;
    IMP orig = method_getImplementation(own);
    if (!orig || orig == hook) return 0;
    if (outOrig && !*outOrig) *outOrig = orig;
    method_setImplementation(own, hook);
    maxlog(@"ghost: hooked %s %s orig=%p", class_getName(cls), sel_getName(sel), orig);
    return 1;
}

static void max_installGhostHooks(void) {
    // Owner in the class dump is OKMChatHandler (markAsReadTo:messageId: at
    // 0x100843fa8, markReactionAsReadTo:messageId: at 0x10084418c). Walk a
    // tiny allow-list first; only then scan the class list as a safety net
    // so a renamed class still gets hooked — but we store ONE orig IMP.
    SEL readSel = sel_registerName("markAsReadTo:messageId:");
    SEL reactSel = sel_registerName("markReactionAsReadTo:messageId:");
    IMP hook = (IMP)max_hook_read2;

    const char *prefer[] = { "OKMChatHandler", "OKMChatService", NULL };
    int hits = 0;
    for (int i = 0; prefer[i]; i++) {
        Class cls = objc_getClass(prefer[i]);
        hits += max_hookOwnSel(cls, readSel, hook, &g_origMarkAsRead);
        hits += max_hookOwnSel(cls, reactSel, hook, &g_origMarkReactionAsRead);
    }

    if (!g_origMarkAsRead || !g_origMarkReactionAsRead) {
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        for (unsigned i = 0; i < classCount; i++) {
            Class cls = classes[i];
            if (!g_origMarkAsRead)
                hits += max_hookOwnSel(cls, readSel, hook, &g_origMarkAsRead);
            if (!g_origMarkReactionAsRead)
                hits += max_hookOwnSel(cls, reactSel, hook, &g_origMarkReactionAsRead);
            if (g_origMarkAsRead && g_origMarkReactionAsRead) break;
        }
        free(classes);
    }
    maxlog(@"ghost: read-hooks %d  origRead=%p origReact=%p  block=%d",
           hits, g_origMarkAsRead, g_origMarkReactionAsRead, (int)g_blockRead);
}

static IMP orig_deleteMessageCtx = NULL;

// ============================================================================
#if 0  // v10.0: two-phase delete + tasks tracing REMOVED
#pragma mark - Keep-deleted: TWO-PHASE delete (switch-controlled)
//
// With mod.del ON:
//   1st delete of a message -> the message STAYS but gets visually marked
//                              (cell rendered at 45% opacity);
//   2nd delete of an already-marked message -> deleted for real.
// The user sees what was "deleted" and can confirm-kill each one by
// deleting it again. With mod.del OFF — normal deletes throughout.
//
// Marking: the message's primaryKey is remembered in a set; a swizzle on
// the message cell's layout dims the cell when its message is marked.
// ============================================================================

static NSString *max_primaryKeyOfMessage(id message) {
    if (!message) return nil;
    SEL sel = sel_registerName("primaryKey");
    if ([message respondsToSelector:sel])
        return [NSString stringWithFormat:@"%@", ((id(*)(id,SEL))objc_msgSend)(message, sel)];
    @try {
        return [NSString stringWithFormat:@"%@", [message valueForKey:@"primaryKey"]];
    } @catch (NSException *e) {
        return nil;
    }
}

static void hook_deleteMessageCtx(id self, SEL _cmd, id message, id context) {
    if (max_modOn(@"mod.del") && message) {
        NSString *pk = max_primaryKeyOfMessage(message);
        if (pk && max_pkIsApproved(pk)) {
            // an approved deletion for this pk is already in flight — pass through
            maxlog(@"keep-deleted: message %@ delete already in flight, passing", pk);
        } else if (pk && ![g_markedDeleted containsObject:pk]) {
            [g_markedDeleted addObject:pk];
            maxlog(@"keep-deleted: message %@ marked (1st delete)", pk);
            [[NSUserDefaults standardUserDefaults] setObject:[g_markedDeleted allObjects]
                                                      forKey:@"mod.markedDeleted"];

            // v7.3: remember the cell's indexPath for the dim module — the
            // message stays in the data source (deletion blocked), so the
            // indexPath is stable across reuse and restarts.
            if (g_lastMenuCellRef) {
                UIView *cell = (UIView *)g_lastMenuCellRef.target;
                if (cell) {
                    UIView *v = cell.superview;
                    while (v && ![v isKindOfClass:[UICollectionView class]])
                        v = v.superview;
                    if (v) {
                        NSIndexPath *ip = [(UICollectionView *)v indexPathForCell:
                                           (UICollectionViewCell *)cell];
                        if (ip) {
                            NSString *ipKey = [NSString stringWithFormat:@"%ld-%ld",
                                               (long)ip.section, (long)ip.item];
                            NSMutableArray *ips = [[[NSUserDefaults standardUserDefaults]
                                stringArrayForKey:@"mod.markedIndexPaths"] mutableCopy]
                                ?: [NSMutableArray array];
                            [ips addObject:ipKey];
                            [[NSUserDefaults standardUserDefaults] setObject:ips
                                                                      forKey:@"mod.markedIndexPaths"];
                            maxlog(@"keep-deleted: marked indexPath %@", ipKey);
                        }
                    }
                }
            }
            return;
        }
        if (pk) {
            [g_markedDeleted removeObject:pk];
            [[NSUserDefaults standardUserDefaults] setObject:[g_markedDeleted allObjects]
                                                      forKey:@"mod.markedDeleted"];
            // drop the recorded indexPath so the cell un-dims
            NSMutableArray *ips = [[[NSUserDefaults standardUserDefaults]
                stringArrayForKey:@"mod.markedIndexPaths"] mutableCopy];
            [ips removeLastObject];
            [[NSUserDefaults standardUserDefaults] setObject:(ips ?: @[])
                                                      forKey:@"mod.markedIndexPaths"];
            // approve the pk so the chat-service hook lets the REAL deletion
            // through (windowed: the public -> private call chain needs it
            // alive across several invocations)
            if (!g_approvedDeletePks) g_approvedDeletePks = [NSMutableDictionary new];
            g_approvedDeletePks[pk] = [NSDate date];
            maxlog(@"keep-deleted: message %@ really deleted (2nd delete, approved 30s)", pk);
        }
    }
    if (orig_deleteMessageCtx)
        ((void(*)(id,SEL,id,id))orig_deleteMessageCtx)(self, _cmd, message, context);
}

// dim marked cells: hook MessageCell's applyLayoutAttributes/layoutSubviews
static IMP orig_cellLayout = NULL;

static void hook_cellApplyLayout(id self, SEL _cmd, id attrs) {
    ((void(*)(id,SEL,id))orig_cellLayout)(self, _cmd, attrs);
    @try {
        id msg = [self valueForKey:@"message"];
        // MessageCell keeps the message in a viewModel; try common paths
        if (!msg) {
            id vm = [self valueForKey:@"viewModel"];
            if (vm) msg = [vm valueForKey:@"message"];
        }
        NSString *pk = max_primaryKeyOfMessage(msg);
        [self setAlpha:([g_markedDeleted containsObject:pk] ? 0.45 : 1.0)];
    } @catch (NSException *e) {
        // keep the cell visible whatever its internals are
    }
}

static void max_installKeepDeletedHook(void) {
    // restore the marked set from previous runs
    NSArray *saved = [[NSUserDefaults standardUserDefaults]
        stringArrayForKey:@"mod.markedDeleted"];
    g_markedDeleted = [NSMutableSet setWithArray:(saved ?: @[])];
    maxlog(@"keep-deleted: %lu message(s) marked from previous run",
           (unsigned long)g_markedDeleted.count);

    Class cls = objc_getClass("OMMessageActionProcessor");
    if (!cls) {
        maxlog(@"keep-deleted: OMMessageActionProcessor not found");
        return;
    }
    SEL sel = sel_registerName("_deleteMessage:context:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        maxlog(@"keep-deleted: _deleteMessage:context: not found");
        return;
    }
    orig_deleteMessageCtx = method_getImplementation(m);
    method_setImplementation(m, (IMP)hook_deleteMessageCtx);
    maxlog(@"keep-deleted: two-phase own-delete hook installed");

    // dim rendering on the message cell
    Class cell = objc_getClass("_TtC13ChatHistoryUI11MessageCell");
    if (cell) {
        Method lm = class_getInstanceMethod(cell, @selector(applyLayoutAttributes:));
        if (lm) {
            orig_cellLayout = method_getImplementation(lm);
            method_setImplementation(lm, (IMP)hook_cellApplyLayout);
            maxlog(@"keep-deleted: cell dim hook installed");
        } else {
            maxlog(@"keep-deleted: applyLayoutAttributes: not found on cell");
        }
    }
}

// ============================================================================
#pragma mark - «Моды» settings tab (ported from Mods.dylib v6, in ObjC)
// ============================================================================

#endif  // end removed block 2 (two-phase + traces)
@interface MAXModsViewController : UITableViewController
@end

static NSString *const kModCell = @"maxmodcell";

typedef struct {
    NSString *title;
    NSString *key;
    NSString *subtitle;
} ModEntry;

static ModEntry max_modEntries[] = {
    { .title = @"Не отправлять «прочитано»", .key = @"mod.read",
      .subtitle = @"Выкл = обычные галочки. Вкл = собеседник не видит прочтение" },
};
static NSUInteger const kModCount = sizeof(max_modEntries) / sizeof(max_modEntries[0]);

@implementation MAXModsViewController

// Потужно flag header: blue over yellow bar + wordmark, sits above the table.
- (UIView *)max_makeHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 132)];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 12, 288, 104)];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    card.layer.cornerRadius = 18;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.masksToBounds = YES;
    card.backgroundColor = max_potuzhnoBlue();
    [header addSubview:card];

    // bottom yellow band = the flag
    UIView *band = [[UIView alloc] initWithFrame:CGRectMake(0, 52, 288, 52)];
    band.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    band.backgroundColor = max_potuzhnoYellow();
    [card addSubview:band];

    UILabel *title = [[UILabel alloc] initWithFrame:card.bounds];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont systemFontOfSize:30 weight:UIFontWeightHeavy];
    title.text = @"ПОТУЖНО";
    title.textColor = UIColor.whiteColor;
    title.layer.shadowColor = [UIColor colorWithWhite:0 alpha:0.35].CGColor;
    title.layer.shadowOffset = CGSizeMake(0, 1);
    title.layer.shadowOpacity = 1;
    title.layer.shadowRadius = 3;
    [card addSubview:title];

    return header;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Моды";
    self.tableView.tableHeaderView = [self max_makeHeader];
    if (@available(iOS 13.0, *))
        self.navigationController.navigationBar.tintColor = max_potuzhnoBlue();
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return (s == 0) ? @"Приватность" : @"Отладка";
}

- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view
       forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *h = (UITableViewHeaderFooterView *)view;
        h.textLabel.textColor = max_potuzhnoBlue();
        h.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return (s == 0)
        ? @"Тумблеры хранятся на устройстве и работают сразу."
        : @"Лог пишется в Documents/maxmods_log.txt.";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (s == 0) ? (NSInteger)kModCount : 3;   // 0: mods, 1: log actions
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 1) {
        // log actions: view / share / clear
        static NSString *kLogCell = @"maxlogcell";
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:kLogCell];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                    reuseIdentifier:kLogCell];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        NSArray *titles = @[ @"Посмотреть логи", @"Отправить логи", @"Очистить логи" ];
        NSArray *icons = @[ @"doc.text", @"square.and.arrow.up", @"trash" ];
        cell.textLabel.text = titles[ip.row];
        cell.imageView.image = [UIImage systemImageNamed:icons[ip.row]];
        cell.imageView.tintColor = (ip.row == 2)
            ? [UIColor systemRedColor] : max_potuzhnoBlue();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:kModCell];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                    reuseIdentifier:kModCell];
        UISwitch *sw = [UISwitch new];
        sw.onTintColor = max_potuzhnoBlue();
        [sw addTarget:self action:@selector(switchChanged:)
             forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        cell.detailTextLabel.numberOfLines = 0;
        // leading Потужно accent bar on each mod row
        UIView *accent = [[UIView alloc] initWithFrame:CGRectMake(0, 6, 3, 40)];
        accent.tag = 7001;
        accent.backgroundColor = max_potuzhnoYellow();
        accent.layer.cornerRadius = 1.5;
        [cell.contentView addSubview:accent];
    }
    UIView *accent = [cell.contentView viewWithTag:7001];
    accent.frame = CGRectMake(0, 6, 3, cell.contentView.bounds.size.height - 12);
    ModEntry e = max_modEntries[ip.row];
    cell.textLabel.text = e.title;
    cell.detailTextLabel.text = e.subtitle;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    [(UISwitch *)cell.accessoryView setOn:max_modOn(e.key)];
    [(UISwitch *)cell.accessoryView setTag:ip.row];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return (ip.section == 0) ? 64.0 : 48.0;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != 1) return;
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.row == 0) {
        // viewer: last 800 lines of the log in a read-only text screen
        UITextView *tv2 = [[UITextView alloc] initWithFrame:CGRectZero];
        tv2.editable = NO;
        tv2.font = [UIFont fontWithName:@"Menlo" size:11]
                   ?: [UIFont systemFontOfSize:12];
        tv2.backgroundColor = UIColor.systemBackgroundColor;
        NSString *path = max_logPath();
        NSString *full = [NSString stringWithContentsOfFile:path
                                encoding:NSUTF8StringEncoding error:nil] ?: @"(пусто)";
        NSArray *lines = [full componentsSeparatedByString:@"\n"];
        if (lines.count > 800)
            lines = [lines subarrayWithRange:
                NSMakeRange(lines.count - 800, 800)];
        tv2.text = [[NSString alloc] initWithFormat:@"...\n%@",
                     [lines componentsJoinedByString:@"\n"]];
        UIViewController *vc = [[UIViewController alloc] init];
        vc.title = @"Логи";
        [vc loadViewIfNeeded];
        tv2.frame = vc.view.bounds;
        tv2.autoresizingMask = UIViewAutoresizingFlexibleWidth
                               | UIViewAutoresizingFlexibleHeight;
        [vc.view addSubview:tv2];
        [self.navigationController pushViewController:vc animated:YES];
    } else if (ip.row == 1) {
        // share sheet with the log file
        NSURL *url = [NSURL fileURLWithPath:max_logPath()];
        UIActivityViewController *av = [[UIActivityViewController alloc]
            initWithActivityItems:@[url] applicationActivities:nil];
        [self presentViewController:av animated:YES completion:nil];
    } else if (ip.row == 2) {
        // truncate in place (atomically:NO): an atomic write swaps
        // the inode and detaches the cached crash fd
        [@"" writeToFile:max_logPath() atomically:NO
              encoding:NSUTF8StringEncoding error:nil];
        maxlog(@"log: cleared by user");
        UIAlertController *al = [UIAlertController
            alertControllerWithTitle:@"Логи очищены" message:nil
             preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"Ок" style:UIAlertActionStyleDefault
                                             handler:nil]];
        [self presentViewController:al animated:YES completion:nil];
    }
}

- (void)switchChanged:(UISwitch *)sw {
    if (sw.tag >= (NSInteger)kModCount) return;
    ModEntry e = max_modEntries[sw.tag];
    if ([e.key isEqualToString:@"mod.read"]) {
        max_setModRead(sw.on);
    } else {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setBool:sw.on forKey:e.key];
        [d synchronize];
    }
    maxlog(@"mods: %@ -> %@ (blockRead=%d)", e.key,
           sw.on ? @"ON" : @"OFF", (int)g_blockRead);
}

@end

static BOOL max_tabHasMods(UITabBarController *tbc) {
    for (UIViewController *vc in tbc.viewControllers) {
        if ([vc isKindOfClass:[MAXModsViewController class]]) return YES;
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *top = ((UINavigationController *)vc).topViewController;
            if ([top isKindOfClass:[MAXModsViewController class]]) return YES;
        }
    }
    return NO;
}

static UINavigationController *max_makeModsNav(void) {
    MAXModsViewController *vc = [[MAXModsViewController alloc]
        initWithStyle:UITableViewStyleGrouped];
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:vc];
    UITabBarItem *item = [[UITabBarItem alloc]
        initWithTitle:@"Моды"
                image:[UIImage systemImageNamed:@"gearshape.2"]
                  tag:999];
    nav.tabBarItem = item;
    return nav;
}

static void max_injectModsTab(void);
static void maxmods_tabBarLongPressImp(id self, SEL _cmd,
                                       UILongPressGestureRecognizer *gesture);
static void max_attachModsLongPress(id tabBarController);

static void max_retryModsTab(void) {
    static int triesLeft = 180;   // ~3 min of retries after launch
    if (triesLeft <= 0) return;
    triesLeft--;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ max_injectModsTab(); });
}

// Depth-first search for a UITabBarController anywhere in the VC tree —
// MAX wraps its tab bar in custom containers, so rootViewController is
// not the tab bar itself.
static UITabBarController *max_findTabBar(UIViewController *vc, int depth) {
    if (!vc || depth > 6) return nil;
    if ([vc isKindOfClass:[UITabBarController class]])
        return (UITabBarController *)vc;
    UITabBarController *found = max_findTabBar(vc.presentedViewController, depth + 1);
    if (found) return found;
    for (UIViewController *child in vc.childViewControllers) {
        found = max_findTabBar(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void max_injectModsTab(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindow *win = ((UIWindowScene *)scene).keyWindow
                        ?: ((UIWindowScene *)scene).windows.firstObject;
        if (!win) continue;

        UITabBarController *tbc = max_findTabBar(win.rootViewController, 0);
        if (!tbc) continue;

        // Always (re)attach the long-press to the LIVE tab bar — this is the
        // reliable entry even on warm launches where viewDidLoad never re-fired.
        if (![tbc respondsToSelector:@selector(maxmods_tabBarLongPress:)])
            class_addMethod([tbc class], @selector(maxmods_tabBarLongPress:),
                            (IMP)maxmods_tabBarLongPressImp, "v@:@");
        max_attachModsLongPress(tbc);

        if (max_tabHasMods(tbc)) return;   // tab already there
        if (tbc.viewControllers.count < 2) { max_retryModsTab(); return; }
        NSMutableArray *vcs = [tbc.viewControllers mutableCopy];
        [vcs addObject:max_makeModsNav()];
        [tbc setViewControllers:vcs animated:NO];
        // the app uses a custom tab bar that may not relayout on its own
        [tbc.view setNeedsLayout];
        [tbc.view layoutIfNeeded];
        maxlog(@"mods: tab injected (root=%@)",
               NSStringFromClass(win.rootViewController.class));
        return;
    }
    max_retryModsTab();
}

static void max_periodicModsTabCheck(void) {
    // the app can rebuild its tab bar (e.g. after login state changes)
    dispatch_async(dispatch_get_main_queue(), ^{ max_injectModsTab(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                   ^{ max_periodicModsTabCheck(); });
}

// ============================================================================
#pragma mark - Моды via long-press on the LAST tab (Settings/Profile)
//
// The reliable entry point from the old tweak (commit 7a437bb): a long-press
// recognizer on the app's custom tab bar view — the tab bar exists no matter
// how the controller tree is wrapped. Long-press the Settings/Profile tab
// (the last one) for 0.5s to open the Моды screen as a modal.
// ============================================================================

static void maxmods_tabBarLongPressImp(id self, SEL _cmd,
                                       UILongPressGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    UIView *tabBarView = gesture.view;
    CGPoint point = [gesture locationInView:tabBarView];
    maxlog(@"mods: long-press BEGAN on %@ at x=%.0f w=%.0f",
           NSStringFromClass(tabBarView.class), point.x, tabBarView.bounds.size.width);

    // v12.6: any 0.5s long-press ON THE TAB BAR opens Моды. The old
    // "last item only" x-math failed once the Моды tab was injected (the
    // last slot became Моды, not Settings) and on MAX's custom bar where the
    // item rects don't map to width/count. A deliberate long-press on the
    // small bottom strip is intentional enough — no position filter.
    UIViewController *host = nil;
    UIResponder *responder = tabBarView;
    while (responder && ![responder isKindOfClass:[UIViewController class]])
        responder = responder.nextResponder;
    host = (UIViewController *)responder;
    // climb to the topmost presenter so present never fails on an already-
    // presenting controller
    UIViewController *top = host;
    while (top.presentedViewController) top = top.presentedViewController;
    if (!top) { maxlog(@"mods: long-press — no host VC"); return; }
    // already showing Моды? don't stack a second one
    for (UIViewController *c = top; c; c = c.presentingViewController) {
        if ([c isKindOfClass:[MAXModsViewController class]]) return;
        if ([c isKindOfClass:[UINavigationController class]] &&
            [((UINavigationController *)c).topViewController isKindOfClass:[MAXModsViewController class]])
            return;
    }

    MAXModsViewController *modsVC = [[MAXModsViewController alloc]
        initWithStyle:UITableViewStyleGrouped];
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:modsVC];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    modsVC.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                       target:modsVC
                                                       action:@selector(maxmods_dismiss)];
    [top presentViewController:nav animated:YES completion:^{
        maxlog(@"mods: opened via long-press (present completed)");
    }];
    maxlog(@"mods: opened via long-press on tab bar (host=%@)",
           NSStringFromClass([top class]));
}

// helper: dismiss for the Done button
__attribute__((unused))
static void maxmods_dismissImp(id self, SEL _cmd) {
    UIViewController *vc = (UIViewController *)self;
    [vc dismissViewControllerAnimated:YES completion:nil];
}

static IMP orig_tabBarViewDidLoad = NULL;

// Gesture delegate: a UILongPressGestureRecognizer added to UITabBar never
// fired because the tab BUTTONS (UIControls) swallow the touch before the
// bar's recognizer can begin — no "long-press BEGAN" ever appeared in the
// device log. shouldReceiveTouch:YES forces the recognizer to see touches
// even on those controls; simultaneous-recognition lets the normal tab tap
// still work.
@interface MAXLongPressDelegate : NSObject <UIGestureRecognizerDelegate>
@end
@implementation MAXLongPressDelegate
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    return YES;
}
@end
static MAXLongPressDelegate *g_lpDelegate = nil;

// Recursively locate the real tab-bar view. MAX wraps its bar in custom
// containers, so a UITabBar may sit several levels below the VC's view.
static UIView *max_findTabBarView(UIView *root, int depth) {
    if (!root || depth > 8) return nil;
    if ([root isKindOfClass:[UITabBar class]]) return root;
    NSString *cls = NSStringFromClass(root.class);
    if ([cls rangeOfString:@"TabBar"].location != NSNotFound &&
        [cls rangeOfString:@"Controller"].location == NSNotFound &&
        root.subviews.count > 0)
        return root;
    for (UIView *sub in root.subviews) {
        UIView *found = max_findTabBarView(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

// Attach the 0.5s long-press once, wherever the tab bar currently lives.
// Called from viewDidLoad AND the periodic tab check so a warm launch (no
// fresh viewDidLoad) or a rebuilt tab bar still gets the gesture.
static void max_attachModsLongPress(id tabBarController) {
    if (![tabBarController isKindOfClass:[UIViewController class]]) return;
    UIView *barView = nil;
    if ([tabBarController isKindOfClass:[UITabBarController class]])
        barView = ((UITabBarController *)tabBarController).tabBar;
    if (!barView)
        barView = max_findTabBarView(((UIViewController *)tabBarController).view, 0);
    if (!barView) {
        maxlog(@"mods: no tab-bar view to attach long-press");
        return;
    }
    for (UIGestureRecognizer *g in barView.gestureRecognizers) {
        if ([g isKindOfClass:[UILongPressGestureRecognizer class]] &&
            ((UILongPressGestureRecognizer *)g).minimumPressDuration == 0.5)
            return;   // already attached
    }
    if (!g_lpDelegate) g_lpDelegate = [MAXLongPressDelegate new];
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:tabBarController action:@selector(maxmods_tabBarLongPress:)];
    lp.minimumPressDuration = 0.5;
    lp.cancelsTouchesInView = NO;
    lp.delaysTouchesBegan = NO;
    lp.delaysTouchesEnded = NO;
    lp.delegate = g_lpDelegate;   // receive touches even on the tab buttons
    [barView addGestureRecognizer:lp];
    maxlog(@"mods: long-press gesture attached to %@ (host %@)",
           NSStringFromClass(barView.class), NSStringFromClass([tabBarController class]));
}

static void hook_tabBarViewDidLoad(id self, SEL _cmd) {
    if (orig_tabBarViewDidLoad)
        ((void(*)(id,SEL))orig_tabBarViewDidLoad)(self, _cmd);
    // defer once: the custom tab bar is often built after viewDidLoad returns
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ max_attachModsLongPress(self); });
    max_attachModsLongPress(self);
}

// ============================================================================
#pragma mark - Session Fix: Keychain (selective)
// ============================================================================

static NSString *const kOrigTeam = @"6T4347P359";
static IMP orig_kcClass = NULL;
static IMP orig_kcInit = NULL;

static id hook_kcClass(id self, SEL _cmd, id service, NSString *group) {
    if (!orig_kcClass) return nil;
    if (group && [group containsString:kOrigTeam]) {
        return ((id(*)(id,SEL,id,id))orig_kcClass)(self, _cmd, service, nil);
    }
    return ((id(*)(id,SEL,id,id))orig_kcClass)(self, _cmd, service, group);
}

static id hook_kcInit(id self, SEL _cmd, id service, NSString *group) {
    if (!orig_kcInit) return nil;
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
    if (!orig_containerURL) return nil;
    return ((NSURL*(*)(id,SEL,NSString*))orig_containerURL)(self, _cmd, groupId);
}

// ============================================================================
#pragma mark - Session Fix: NSUserDefaults Suite
// ============================================================================

static IMP orig_initSuite = NULL;

static id hook_initSuite(id self, SEL _cmd, NSString *name) {
    if (!orig_initSuite) return nil;
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
    maxlog(@"v12.4-FULLLOG loading (sync flush, crash dump, watchdog stack, lifecycle), overlay polish, Потужно strings)...");

    // 0) Crash catcher first: if anything below (or the async server response
    //    handling) kills the process, the backtrace lands in this log.
    max_installCrashCatcher();

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

    // 3) Ads & junk blocker: promo banners, informer banners, suggested
    //    chats, myTarget ad id — all neutralized.
    max_installBrandIcons();
    max_installBrandStrings();
    max_installAdBlocker();

    // 4) Feature pruning: stories / Digital ID / mini-apps / channels,
    //    plus junk rows on the settings screens.
    max_installFeaturePruner();
    max_installSettingsPruner();

    // defaults FIRST — g_blockRead must match the stored switch before any
    // markAsRead call can race the constructor. Missing key => ON (privacy).
    {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        for (NSUInteger i = 0; i < kModCount; i++) {
            ModEntry e = max_modEntries[i];
            if ([e.key isEqualToString:@"mod.sysmenu"]) {
                if ([d objectForKey:e.key] == nil) [d setBool:NO forKey:e.key];
                continue;
            }
            if ([d objectForKey:e.key] == nil) [d setBool:YES forKey:e.key];
        }
        if ([d objectForKey:@"mod.read"] != nil)
            g_blockRead = [d boolForKey:@"mod.read"];
        else
            g_blockRead = YES;
        [d synchronize];
        maxlog(@"mods: restored mod.read=%d", (int)g_blockRead);
    }

    // 5) Ghost hooks — v12.3: dedicated orig IMPs so OFF actually sends.
    max_installGhostHooks();
    max_installSysmenuDiagnostics();

    // 6) «Моды» entry points:
    //    a) long-press (0.5s) the LAST tab (Settings) — the reliable way,
    //       ported from the old tweak (7a437bb);
    //    b) keep trying to inject a dedicated tab as well.
    {
        Class tabBarVC = objc_getClass("_TtC7OMUIKit16TabBarController");
        if (tabBarVC) {
            class_addMethod(tabBarVC, @selector(maxmods_tabBarLongPress:),
                (IMP)maxmods_tabBarLongPressImp, "v@:@");
            class_addMethod([MAXModsViewController class], @selector(maxmods_dismiss),
                (IMP)maxmods_dismissImp, "v@:");
            orig_tabBarViewDidLoad = swizzle(tabBarVC,
                @selector(viewDidLoad), (IMP)hook_tabBarViewDidLoad);
            maxlog(@"mods: tab-bar long-press hook: %@",
                   orig_tabBarViewDidLoad ? @"OK" : @"MISS");
        } else {
            maxlog(@"WARNING: OMUIKit TabBarController class not found");
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ max_injectModsTab(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                   ^{ max_periodicModsTabCheck(); });

    // 7) Session persistence fixes (unchanged from v3.0).
    Class kc = objc_getClass("UICKeyChainStore");
    if (kc) {
        orig_kcClass = swizzleClassMethod(kc,
            @selector(keyChainStoreWithService:accessGroup:), (IMP)hook_kcClass);
        orig_kcInit = swizzle(kc,
            @selector(initWithService:accessGroup:), (IMP)hook_kcInit);
        maxlog(@"Keychain fix: class %@, init %@",
               orig_kcClass ? @"OK" : @"MISS", orig_kcInit ? @"OK" : @"MISS");
    }

    orig_containerURL = swizzle([NSFileManager class],
        @selector(containerURLForSecurityApplicationGroupIdentifier:),
        (IMP)hook_containerURL);

    orig_initSuite = swizzle([NSUserDefaults class],
        @selector(initWithSuiteName:), (IMP)hook_initSuite);

    max_scheduleWatchdog();

    // FULL-LOG: lifecycle + memory warnings
    @try {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
            maxlog(@"LIFECYCLE: didReceiveMemoryWarning");
            NSArray *st = [NSThread callStackSymbols];
            if (st.count > 30) st = [st subarrayWithRange:NSMakeRange(0,30)];
            maxlog(@"LIFECYCLE: stack at warning:\n%@", [st componentsJoinedByString:@"\n"]);
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
            maxlog(@"LIFECYCLE: willTerminate");
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
            maxlog(@"LIFECYCLE: didEnterBackground");
        }];
        maxlog(@"LIFECYCLE: observers installed (memory/terminate/background)");
    } @catch (NSException *e) { maxlog(@"LIFECYCLE: observer install failed %@", e); }

    // bump version string in log so we know FULL-LOG is active
    maxlog(@"v12.4-FULLLOG loaded OK — log file: %@ (sync/fsync, watchdog stack, crash dump, lifecycle)", max_logPath());
    maxlog(@"v12.7 loaded OK (long-press delegate: receive touches on tab buttons) — log file: %@", max_logPath());
}

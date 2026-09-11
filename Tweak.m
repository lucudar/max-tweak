/**
 * MAXMods v6.2 — «Потужно Мессенджер»: menu + ghost mode + Моды tab + ad blocker
 * (menu above the bubble, reliable tap-outside dismissal)
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

// A menu row: fixed-size leading icon + left-aligned title, laid out by hand.
// UIButtonConfiguration misaligned icons over long titles (icon overlapping
// "Delete", truncated "Save to Gallery") — manual layout is predictable.
@interface MAXMenuItemButton : UIControl
@property (nonatomic, strong, readonly) NSString *actionTitle;
@end

@interface MAXMenuItemButton ()
@property (nonatomic, strong) UIAction *action;
@property (nonatomic, strong) UILabel *titleLabel2;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UIView *highlightView;
@end

@implementation MAXMenuItemButton

- (instancetype)initWithFrame:(CGRect)frame action:(UIAction *)action {
    if ((self = [super initWithFrame:frame])) {
        UIColor *tint = UIColor.labelColor;
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

        // fire the app's own handler on tap
        [self addTarget:self action:@selector(fire)
              forControlEvents:UIControlEventTouchUpInside];
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
    UIControl *ghost = [[UIControl alloc] initWithFrame:CGRectZero];
    [ghost addAction:_action forControlEvents:UIControlEventPrimaryActionTriggered];
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
    UIView *_panel;
    BOOL _itemFired;
}

+ (BOOL)isShowing { return g_overlay != nil; }

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

// Dismiss on any tap outside the panel. Wired via BOTH a tap gesture and
// UIControlEventTouchUpInside — a bare UIControl does not reliably deliver
// UIControlEventPrimaryActionTriggered, which left the overlay stuck.
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
    [self dismissAnimated:YES];
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
    [bg addTarget:ov action:@selector(tapOutside)
                 forControlEvents:UIControlEventTouchUpInside];
    [bg addTarget:ov action:@selector(tapOutside)
                 forControlEvents:UIControlEventTouchDown];
    UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc]
        initWithTarget:ov action:@selector(tapOutside)];
    [bg addGestureRecognizer:bgTap];
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
        snapView.layer.shadowColor = [UIColor blackColor].CGColor;
        snapView.layer.shadowOpacity = 0.30;
        snapView.layer.shadowRadius = 16;
        snapView.layer.shadowOffset = CGSizeZero;
        [ov addSubview:snapView];
        ov->_snapshotView = snapView;
    }

    // panel: uniform semi-transparent background. Blur looked patchy over
    // mixed content (transparent in places, solid in others); a translucent
    // solid color gives the consistent Telegram-menu look.
    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.layer.cornerRadius = 14;
    panel.layer.masksToBounds = YES;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.backgroundColor =
        [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:0.10 alpha:0.72]
                : [UIColor colorWithWhite:1.0 alpha:0.82];
        }];
    panel.layer.borderWidth = 0.5;
    panel.layer.borderColor =
        [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1 alpha:0.14]
                : [UIColor colorWithWhite:0 alpha:0.10];
        }].CGColor;
    [ov addSubview:panel];
    ov->_panel = panel;

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
              forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:btn];
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
            [panel addSubview:sep];
            y += 0.5;
        }
    }
    y += 5;

    panel.frame = CGRectMake(0, 0, panelWidth, y);

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
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            maxlog(@"ads: method not found: %s -> %s", hooks[i].cls, hooks[i].sel);
            continue;
        }
        method_setImplementation(m, hooks[i].hook);
        maxlog(@"ads: blocked %s -> %s", hooks[i].cls, hooks[i].sel);
    }
}

// ============================================================================
#pragma mark - Ghost mode / keep-deleted hooks (switch-controlled)
//
// Ported from the old Mods.dylib v6 (mods_v6.c), but WITHOUT its two fatal
// mistakes: no mass-swizzle of _deleteMessage:context: (that broke message
// deletion), and no default-on blocking of the app's own delete flow.
// Only privacy selectors are hooked, discovered per-class at startup.
//
// Switches live in NSUserDefaults and are toggled from the Моды tab:
//   mod.read    — don't send read receipts      (block markAsReadTo:messageId:)
//   mod.typing  — don't send typing indicators  (block sendTyping*)
//   mod.online  — always appear offline         (block updateOnline*)
//   mod.del     — keep remotely deleted messages visible (block
//                 _handleDeletedMessages, the INCOMING-deletion handler —
//                 the user's own deletes are untouched)
// ============================================================================

static BOOL max_modOn(NSString *key) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

typedef struct {
    Class cls;
    SEL sel;
    IMP orig;
} ModHook;

static ModHook g_modHooks[128];
static int g_nModHooks = 0;

static IMP max_modOrig(Class cls, SEL sel) {
    for (int i = 0; i < g_nModHooks; i++)
        if (g_modHooks[i].sel == sel && g_modHooks[i].cls == cls)
            return g_modHooks[i].orig;
    for (int i = 0; i < g_nModHooks; i++)     // subclass fallback
        if (g_modHooks[i].sel == sel)
            return g_modHooks[i].orig;
    return NULL;
}

static id max_hook_read2(id self, SEL _cmd, id a, id b) {
    if (max_modOn(@"mod.read")) return nil;   // don't send the receipt
    IMP o = max_modOrig(object_getClass(self), _cmd);
    return o ? ((id(*)(id,SEL,id,id))o)(self, _cmd, a, b) : nil;
}

static void max_hook_void1(id self, SEL _cmd, id a) {
    NSString *n = NSStringFromSelector(_cmd);
    if ([n hasPrefix:@"sendTyping"] && max_modOn(@"mod.typing")) return;
    if (([n hasPrefix:@"updateOnline"] || [n isEqualToString:@"userOnlineStatus:"])
        && max_modOn(@"mod.online")) return;
    IMP o = max_modOrig(object_getClass(self), _cmd);
    if (o) ((void(*)(id,SEL,id))o)(self, _cmd, a);
}

static void max_hook_void0(id self, SEL _cmd) {
    NSString *n = NSStringFromSelector(_cmd);
    if ([n hasPrefix:@"sendTyping"] && max_modOn(@"mod.typing")) return;
    if ([n hasPrefix:@"updateOnline"] && max_modOn(@"mod.online")) return;
    if ([n isEqualToString:@"_handleDeletedMessages"] && max_modOn(@"mod.del")) {
        maxlog(@"ghost: suppressed incoming deletion event");
        return;
    }
    IMP o = max_modOrig(object_getClass(self), _cmd);
    if (o) ((void(*)(id,SEL))o)(self, _cmd);
}

static void max_installGhostHooks(void) {
    struct { const char *sel; int args; } targets[] = {
        {"markAsReadTo:messageId:",          2},
        {"sendTypingNotificationIfNeeded:",  1},
        {"updateOnlineIfNeeded:",            1},
        {"userOnlineStatus:",                1},
        {"sendTypingNotification",           0},
        {"sendStickerTypingNotification",    0},
        {"updateOnlineStatus",               0},
        {"_handleDeletedMessages",           0},
    };
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned t = 0; t < sizeof(targets)/sizeof(targets[0]); t++) {
        SEL sel = sel_registerName(targets[t].sel);
        IMP hook = (targets[t].args == 2) ? (IMP)max_hook_read2
                 : (targets[t].args == 1) ? (IMP)max_hook_void1
                 : (IMP)max_hook_void0;
        int hits = 0;
        for (unsigned i = 0; i < classCount; i++) {
            Method m = class_getInstanceMethod(classes[i], sel);
            if (!m) continue;
            if (g_nModHooks < 128) {
                g_modHooks[g_nModHooks].cls = classes[i];
                g_modHooks[g_nModHooks].sel = sel;
                g_modHooks[g_nModHooks].orig = method_getImplementation(m);
                g_nModHooks++;
            }
            method_setImplementation(m, hook);
            hits++;
        }
        maxlog(@"ghost: hook %s -> %d class(es)", targets[t].sel, hits);
    }
    free(classes);
}

// ============================================================================
#pragma mark - «Моды» settings tab (ported from Mods.dylib v6, in ObjC)
// ============================================================================

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
      .subtitle = @"Собеседник не увидит, что вы прочитали сообщение" },
    { .title = @"Скрывать «печатает…»", .key = @"mod.typing",
      .subtitle = @"Статус набора текста не отправляется" },
    { .title = @"Всегда офлайн", .key = @"mod.online",
      .subtitle = @"Ваш онлайн-статус не обновляется" },
    { .title = @"Сохранять удалённые", .key = @"mod.del",
      .subtitle = @"Удалённые у собеседника сообщения остаются у вас" },
};
static NSUInteger const kModCount = sizeof(max_modEntries) / sizeof(max_modEntries[0]);

@implementation MAXModsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Моды";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)kModCount;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:kModCell];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                    reuseIdentifier:kModCell];
        UISwitch *sw = [UISwitch new];
        [sw addTarget:self action:@selector(switchChanged:)
             forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    ModEntry e = max_modEntries[ip.row];
    cell.textLabel.text = e.title;
    cell.detailTextLabel.text = e.subtitle;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    [(UISwitch *)cell.accessoryView
        setOn:[[NSUserDefaults standardUserDefaults] boolForKey:e.key]];
    [(UISwitch *)cell.accessoryView setTag:ip.row];
    return cell;
}

- (void)switchChanged:(UISwitch *)sw {
    if (sw.tag >= (NSInteger)kModCount) return;
    ModEntry e = max_modEntries[sw.tag];
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:e.key];
    maxlog(@"mods: %@ -> %@", e.key, sw.on ? @"ON" : @"OFF");
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
    MAXModsViewController *vc = [MAXModsViewController new];
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
    for (UIViewController *child in vc.children) {
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

        if (max_tabHasMods(tbc)) return;   // already there
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
    maxlog(@"v6.2 loading (potuzhno: menu layout fix + recursive tab search)...");

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
    max_installAdBlocker();

    // 4) Ghost mode + keep-deleted hooks (switch-controlled, Моды tab).
    max_installGhostHooks();

    // defaults: all mods ON until the user turns them off
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (NSUInteger i = 0; i < kModCount; i++) {
        ModEntry e = max_modEntries[i];
        if ([d objectForKey:e.key] == nil) [d setBool:YES forKey:e.key];
    }

    // 5) «Моды» tab — the tab bar appears after login, retry then re-check.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ max_injectModsTab(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                   ^{ max_periodicModsTabCheck(); });

    // 6) Session persistence fixes (unchanged from v3.0).
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

    maxlog(@"v6.2 loaded OK — log file: %@", max_logPath());
}

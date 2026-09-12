/**
 * MAXMods v8.7 — «Потужно Мессенджер»: full OKMTasksService queue trace,
 * indexPath-based dim, settings view pruning
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
#import <objc/message.h>

static BOOL max_pkIsApproved(NSString *s);   // defined in the keep-deleted section
static BOOL max_ghostPaused(void);           // defined in the keep-deleted section

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
    if (!g_lastMenuCellRef) g_lastMenuCellRef = [MaxMenuCellRef new];
    g_lastMenuCellRef.target = self;
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
                ? [UIColor colorWithWhite:0.10 alpha:0.97]
                : [UIColor colorWithWhite:1.0 alpha:0.98];
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
static void max_hookVoid1(id self, SEL _cmd, id a) { (void)self; (void)_cmd; (void)a; }
static void max_hookVoid0(id self, SEL _cmd) { (void)self; (void)_cmd; }

static IMP orig_setViewControllers = NULL;

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

static void hook_setViewControllers(id self, SEL _cmd, NSArray *vcs) {
    if ([vcs isKindOfClass:[NSArray class]]) {
        NSMutableArray *kept = [NSMutableArray array];
        for (UIViewController *vc in vcs)
            if (!max_isPrunedTab(vc)) [kept addObject:vc];
        if (kept.count != vcs.count)
            maxlog(@"prune: dropped %lu tab(s) from the tab bar",
                   (unsigned long)(vcs.count - kept.count));
        vcs = kept;
    }
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
    };
    for (NSUInteger i = 0; i < sizeof(hooks)/sizeof(hooks[0]); i++) {
        Class cls = objc_getClass(hooks[i].cls);
        if (!cls) {
            maxlog(@"prune: class not found: %s", hooks[i].cls);
            continue;
        }
        SEL sel = sel_registerName(hooks[i].sel);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            maxlog(@"prune: method not found: %s -> %s", hooks[i].cls, hooks[i].sel);
            continue;
        }
        method_setImplementation(m, hooks[i].hook);
        maxlog(@"prune: blocked %s -> %s", hooks[i].cls, hooks[i].sel);
    }

    // Digital ID tab: filter it out whenever the app rebuilds the tab bar
    Class tbc = objc_getClass("_TtC7OMUIKit16TabBarController");
    if (tbc) {
        Method m = class_getInstanceMethod(tbc, @selector(setViewControllers:));
        if (m) {
            orig_setViewControllers = method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_setViewControllers);
            maxlog(@"prune: tab-bar filter installed");
        }
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
    ((void(*)(id,SEL,id))orig_setSections)(self, _cmd, sections);
}

static void max_installSettingsPruner(void) {
    Class cls = objc_getClass("OKMActionsViewModel");
    if (!cls) {
        maxlog(@"settings-prune: OKMActionsViewModel not found");
        return;
    }
    Method m = class_getInstanceMethod(cls, @selector(setSections:));
    if (!m) {
        maxlog(@"settings-prune: setSections: not found");
        return;
    }
    orig_setSections = method_getImplementation(m);
    method_setImplementation(m, (IMP)hook_setSections);
    maxlog(@"settings-prune: installed");
}

// ============================================================================
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
            @"Вернуть уведомления",
            @"Пригласить друзей", @"Invite Friends",
            @"Устройства", @"Devices",
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

static void max_settingsPruneViews(UIView *view, int depth) {
    if (!view || depth > 10) return;

    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        NSString *text = label.text;
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
                    break;
                }
                cursor = cursor.superview;
            }
        }
    }
    for (UIView *sub in view.subviews)
        max_settingsPruneViews(sub, depth + 1);
}

static void max_installSettingsViewPruner(void) {
    // hook viewDidAppear: on every SettingsUI view controller class we can find
    maxlog(@"settings-view-pruner: window observer installed");

    // simpler + universal: observe the key window's VC changes via a
    // repeating light check — the screens re-prune on every appearance
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIWindowDidBecomeVisibleNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        UIWindow *w = note.object;
        if (![w isKindOfClass:[UIWindow class]]) return;
        UIViewController *root = w.rootViewController;
        if (!root) return;
        NSString *cls = NSStringFromClass(root.class);
        if ([cls rangeOfString:@"SettingsUI" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            maxlog(@"settings-screen(root): %@ visible", cls);
            max_settingsPruneViews(root.view, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ max_settingsPruneViews(root.view, 0); });
        }
    }];
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
    if (max_modOn(@"mod.read") && !max_ghostPaused()) return nil;   // don't send the receipt
    IMP o = max_modOrig(object_getClass(self), _cmd);
    return o ? ((id(*)(id,SEL,id,id))o)(self, _cmd, a, b) : nil;
}

static void max_hook_void2(id self, SEL _cmd, id a, id b) {
    NSString *n = NSStringFromSelector(_cmd);
    if ([n hasPrefix:@"_handleDeletedMessages"] && max_modOn(@"mod.del") && !max_ghostPaused()) {
        // The event fans out to every device/account. When it carries a pk
        // we JUST approved (own delete-for-all confirmation), let it apply —
        // otherwise our other logged-in accounts keep the "deleted" message.
        NSArray *items = [a isKindOfClass:[NSArray class]] ? a : (a ? @[a] : @[]);
        for (id item in items) {
            NSString *pk = nil;
            if ([item respondsToSelector:@selector(primaryKey)]) {
                pk = [NSString stringWithFormat:@"%@",
                       ((id(*)(id,SEL))objc_msgSend)(item, @selector(primaryKey))];
            } else if (item) {
                pk = [NSString stringWithFormat:@"%@", item];
            }
            if (pk && max_pkIsApproved(pk)) {
                maxlog(@"ghost: own-delete confirmation passed through (pk %@)", pk);
                IMP o = max_modOrig(object_getClass(self), _cmd);
                if (o) ((void(*)(id,SEL,id,id))o)(self, _cmd, a, b);
                return;
            }
        }
        maxlog(@"ghost: remote deletion event suppressed");
        return;
    }
    IMP o = max_modOrig(object_getClass(self), _cmd);
    if (o) ((void(*)(id,SEL,id,id))o)(self, _cmd, a, b);
}

static void max_hook_void1(id self, SEL _cmd, id a) {
    if (!max_ghostPaused()) {
        NSString *n = NSStringFromSelector(_cmd);
        if ([n hasPrefix:@"sendTyping"] && max_modOn(@"mod.typing")) return;
        if (([n hasPrefix:@"updateOnline"] || [n isEqualToString:@"userOnlineStatus:"])
            && max_modOn(@"mod.online")) return;
    }
    IMP o = max_modOrig(object_getClass(self), _cmd);
    if (o) ((void(*)(id,SEL,id))o)(self, _cmd, a);
}

static void max_hook_void0(id self, SEL _cmd) {
    NSString *n = NSStringFromSelector(_cmd);
    if (max_ghostPaused()) {
        // during the pause every 0-arg hook runs native
    } else if ([n hasPrefix:@"sendTyping"] && max_modOn(@"mod.typing")) return;
    else if ([n hasPrefix:@"updateOnline"] && max_modOn(@"mod.online")) return;
    if ([n isEqualToString:@"_handleDeletedMessages"] && max_modOn(@"mod.del")) {
        // v8.5 HYPOTHESIS TEST: this 0-arg variant is part of the service
        // registry's signal chain — blindly suppressing it may freeze the
        // task queue (delete tasks register but never run). Pass it through
        // WITH logging; the 2-arg variant (the real remote-delete handler)
        // still suppresses foreign deletions.
        maxlog(@"ghost: 0-arg _handleDeletedMessages PASSED (%@)",
               NSStringFromClass([self class]));
        // fall through to the original below
    }
    IMP o = max_modOrig(object_getClass(self), _cmd);
    if (o) ((void(*)(id,SEL))o)(self, _cmd);
}

// ============================================================================
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

// v8.6 "ghost pause": right after a delete is approved, ALL ghost hooks run
// native for a short window — if the task queue needs one of the events we
// suppress (online-status/typing/read/deleted-events) to fire the task, the
// server command goes out during this window.
static NSDate *g_ghostPauseUntil = nil;

static void max_beginGhostPause(void) {
    g_ghostPauseUntil = [NSDate dateWithTimeIntervalSinceNow:15.0];
    maxlog(@"ghost: PAUSED for 15s (delete approved — native flow)");
}

static BOOL max_ghostPaused(void) {
    if (!g_ghostPauseUntil) return NO;
    if (-[g_ghostPauseUntil timeIntervalSinceNow] <= 0) {
        g_ghostPauseUntil = nil;
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
        max_beginGhostPause();                      // v8.6: native window for the queue
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

static void hook_sendDeleteCommand(id self, SEL _cmd, id messages) {
    maxlog(@"server-delete: _sendDeleteCommandForMessages: fired (%@ messages)",
           [messages isKindOfClass:[NSArray class]]
               ? @([messages count]) : @"?");
    ((void(*)(id,SEL,id))orig_sendDeleteCommand)(self, _cmd, messages);
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

static void hook_taskPerformWork(id self, SEL _cmd) {
    maxlog(@"task-trace: OKMDeleteMessagesTask performWorkSignal fired");
    ((void(*)(id,SEL))orig_taskPerformWork)(self, _cmd);
}

static IMP orig_taskSetup = NULL;
static IMP orig_taskPrecond = NULL;

static void hook_taskSetup(id self, SEL _cmd, id registry) {
    maxlog(@"task-trace: setupWithRegistry: %@ (%@)",
           NSStringFromClass([registry class]), registry);
    ((void(*)(id,SEL,id))orig_taskSetup)(self, _cmd, registry);
}

static void hook_taskPrecond(id self, SEL _cmd) {
    id result = ((id(*)(id,SEL))orig_taskPrecond)(self, _cmd);
    maxlog(@"task-trace: preConditionSignals = %@ (%@)",
           NSStringFromClass([result class]), result);
    return;   // already called the original above
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
        {"_handleDeletedMessages:inChatWithId:", 2},   // real remote-delete path
    };
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned t = 0; t < sizeof(targets)/sizeof(targets[0]); t++) {
        SEL sel = sel_registerName(targets[t].sel);
        BOOL isRead = strcmp(targets[t].sel, "markAsReadTo:messageId:") == 0;
        IMP hook = isRead ? (IMP)max_hook_read2
                 : (targets[t].args == 2) ? (IMP)max_hook_void2
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

static IMP orig_deleteMessageCtx = NULL;

// ============================================================================
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
            max_beginGhostPause();
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
        return cell;
    }
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
        vc.view = tv2;
        vc.title = @"Логи";
        tv2.frame = vc.view.bounds;
        tv2.autoresizingMask = UIViewAutoresizingFlexibleWidth
                               | UIViewAutoresizingFlexibleHeight;
        [self.navigationController pushViewController:vc animated:YES];
    } else if (ip.row == 1) {
        // share sheet with the log file
        NSURL *url = [NSURL fileURLWithPath:max_logPath()];
        UIActivityViewController *av = [[UIActivityViewController alloc]
            initWithActivityItems:@[url] applicationActivities:nil];
        [self presentViewController:av animated:YES completion:nil];
    } else if (ip.row == 2) {
        // truncate the log
        [@"" writeToFile:max_logPath() atomically:YES
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

    // custom tab bar: items laid out evenly across the width.
    // 4 slots: chats / people / calls(hidden) / settings — but derive from
    // the bar's direct subviews count when available.
    NSInteger itemCount = 0;
    for (UIView *sub in tabBarView.subviews) itemCount++;
    if (itemCount < 2) itemCount = 4;
    NSInteger tappedIndex =
        (NSInteger)(point.x / (tabBarView.bounds.size.width / MAX(itemCount, 1)));

    // any long-press on the last third of the bar = Settings/Profile area
    if (tappedIndex >= itemCount - 1) {
        UIViewController *host = nil;
        // walk up from the tab bar view to a ViewController able to present
        UIResponder *responder = tabBarView;
        while (responder && ![responder isKindOfClass:[UIViewController class]])
            responder = responder.nextResponder;
        host = (UIViewController *)responder;
        if (!host) return;

        MAXModsViewController *modsVC = [[MAXModsViewController alloc]
            initWithStyle:UITableViewStyleGrouped];
        UINavigationController *nav = [[UINavigationController alloc]
            initWithRootViewController:modsVC];
        modsVC.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                           target:modsVC
                                                           action:@selector(maxmods_dismiss)];
        [host presentViewController:nav animated:YES completion:nil];
        maxlog(@"mods: opened via long-press on tab bar");
    }
}

// helper: dismiss for the Done button
__attribute__((unused))
static void maxmods_dismissImp(id self, SEL _cmd) {
    UIViewController *vc = (UIViewController *)self;
    [vc dismissViewControllerAnimated:YES completion:nil];
}

static IMP orig_tabBarViewDidLoad = NULL;

static void hook_tabBarViewDidLoad(id self, SEL _cmd) {
    ((void(*)(id,SEL))orig_tabBarViewDidLoad)(self, _cmd);

    // attach the long-press recognizer to the tab bar's main view
    UIView *barView = ((UIViewController *)self).view;
    if (!barView) return;
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(maxmods_tabBarLongPress:)];
    lp.minimumPressDuration = 0.5;
    [barView addGestureRecognizer:lp];
    maxlog(@"mods: long-press gesture attached to tab bar");
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
    maxlog(@"v8.8 loading (delete-task dependency drop)...");

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

    // 4) Feature pruning: stories / Digital ID / mini-apps / channels,
    //    plus junk rows on the settings screens.
    max_installFeaturePruner();
    max_installSettingsPruner();
    max_installSettingsViewPruner();

    // 5) Ghost mode + keep-deleted hooks (switch-controlled, Моды tab).
    max_installGhostHooks();
    max_installDeletedFlagHook();
    max_installDeleteForAllHook();
    max_installTasksServiceTrace();
    max_installKeepDeletedHook();

    // v7.6: reset the marked indexPath list once — the v7.5 db-hook bug
    // poisoned it / made cells dim that should not. Keys (message ids)
    // are kept; the dim list rebuilds from real 1st-deletes.
    NSString *resetKey = @"mod.dimListReset.v7.6";
    if (![[NSUserDefaults standardUserDefaults] boolForKey:resetKey]) {
        [[NSUserDefaults standardUserDefaults] setObject:@[]
                                                  forKey:@"mod.markedIndexPaths"];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:resetKey];
        maxlog(@"keep-deleted: dim list reset (one-time v7.6)");
    }

    // defaults: all mods ON until the user turns them off
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (NSUInteger i = 0; i < kModCount; i++) {
        ModEntry e = max_modEntries[i];
        if ([d objectForKey:e.key] == nil) [d setBool:YES forKey:e.key];
    }

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

    maxlog(@"v8.8 loaded OK — log file: %@", max_logPath());
}

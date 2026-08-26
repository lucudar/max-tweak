/**
 * MAXMods v2.0 — Clean debloat for MAX messenger (ru.oneme.app)
 * NO mods that break functionality. Only:
 * - Session persistence fix (keychain, app group, userdefaults)
 * - Remove ads/banners
 * - Block trackers/analytics
 * - Settings tab
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ============================================================================
#pragma mark - Settings
// ============================================================================

static NSString *const kRemoveAdsKey = @"maxmods.removeAds";
static NSString *const kBlockTrackersKey = @"maxmods.blockTrackers";

static BOOL removeAdsEnabled = YES;
static BOOL blockTrackersEnabled = YES;

static void loadPrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:kRemoveAdsKey]) [d setBool:YES forKey:kRemoveAdsKey];
    if (![d objectForKey:kBlockTrackersKey]) [d setBool:YES forKey:kBlockTrackersKey];
    removeAdsEnabled = [d boolForKey:kRemoveAdsKey];
    blockTrackersEnabled = [d boolForKey:kBlockTrackersKey];
}

static void savePrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:removeAdsEnabled forKey:kRemoveAdsKey];
    [d setBool:blockTrackersEnabled forKey:kBlockTrackersKey];
    [d synchronize];
}

// ============================================================================
#pragma mark - Swizzle Helper
// ============================================================================

static IMP swizzle(Class cls, SEL sel, IMP newImp) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NULL;
    IMP orig = method_getImplementation(method);
    method_setImplementation(method, newImp);
    return orig;
}

// ============================================================================
#pragma mark - SESSION FIX: Keychain
// ============================================================================

static IMP orig_keyChainStoreWithServiceAccessGroup = NULL;
static IMP orig_initWithServiceAccessGroup = NULL;

static id hook_kcWithService(id self, SEL _cmd, id service, id group) {
    return ((id(*)(id,SEL,id,id))orig_keyChainStoreWithServiceAccessGroup)(self, _cmd, service, nil);
}
static id hook_kcInitService(id self, SEL _cmd, id service, id group) {
    return ((id(*)(id,SEL,id,id))orig_initWithServiceAccessGroup)(self, _cmd, service, nil);
}

// ============================================================================
#pragma mark - SESSION FIX: App Group Container
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
#pragma mark - SESSION FIX: NSUserDefaults Suite
// ============================================================================

static IMP orig_initWithSuiteName = NULL;

static id hook_initWithSuiteName(id self, SEL _cmd, NSString *name) {
    if ([name isEqualToString:@"group.ru.oneme.app"]) {
        return [NSUserDefaults standardUserDefaults];
    }
    return ((id(*)(id,SEL,NSString*))orig_initWithSuiteName)(self, _cmd, name);
}

// ============================================================================
#pragma mark - Remove Ads (safe — only block fetch, no UI swizzle)
// ============================================================================

static void hook_doNothing(id self, SEL _cmd) {
    // no-op: suppress ad/tracker network calls
}

// ============================================================================
#pragma mark - Settings UI
// ============================================================================

@interface MAXModsSettingsController : UITableViewController
@end

@implementation MAXModsSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"MAXMods";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"Debloat" : @"Инфо";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (ip.section == 0) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.tag = ip.row;
        [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        if (ip.row == 0) { cell.textLabel.text = @"Без рекламы"; sw.on = removeAdsEnabled; }
        else { cell.textLabel.text = @"Блокировка трекеров"; sw.on = blockTrackersEnabled; }
    } else {
        cell.textLabel.text = @"MAXMods";
        cell.detailTextLabel.text = @"v2.0 debloat";
    }
    return cell;
}

- (void)toggled:(UISwitch *)sw {
    if (sw.tag == 0) removeAdsEnabled = sw.on;
    else blockTrackersEnabled = sw.on;
    savePrefs();
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

@end

// ============================================================================
#pragma mark - Long-press tab + settings button
// ============================================================================

static IMP orig_tabBarVDL = NULL;
static IMP orig_settingsVDL = NULL;

static void openModsFrom(UIViewController *presenter) {
    MAXModsSettingsController *vc = [[MAXModsSettingsController alloc] initWithStyle:UITableViewStyleGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    vc.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:vc action:@selector(dismissSelf)];
    [presenter presentViewController:nav animated:YES completion:nil];
}

static void hook_tabBarVDL(id self, SEL _cmd) {
    if (orig_tabBarVDL) ((void(*)(id,SEL))orig_tabBarVDL)(self, _cmd);
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(maxmods_lp:)];
    lp.minimumPressDuration = 0.5;
    [((UITabBarController*)self).tabBar addGestureRecognizer:lp];
}

static void maxmods_lpImp(id self, SEL _cmd, UILongPressGestureRecognizer *g) {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UITabBar *bar = (UITabBar *)g.view;
    CGPoint pt = [g locationInView:bar];
    NSArray *items = bar.items;
    if (!items.count) return;
    CGFloat w = bar.bounds.size.width / items.count;
    if ((NSInteger)(pt.x / w) == (NSInteger)items.count - 1)
        openModsFrom((UIViewController *)self);
}

static void hook_settingsVDL(id self, SEL _cmd) {
    if (orig_settingsVDL) ((void(*)(id,SEL))orig_settingsVDL)(self, _cmd);
    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"Моды"
        style:UIBarButtonItemStylePlain target:self action:@selector(maxmods_open)];
    ((UIViewController*)self).navigationItem.rightBarButtonItem = btn;
}

static void maxmods_openImp(id self, SEL _cmd) {
    MAXModsSettingsController *vc = [[MAXModsSettingsController alloc] initWithStyle:UITableViewStyleGrouped];
    [((UIViewController*)self).navigationController pushViewController:vc animated:YES];
}

// ============================================================================
#pragma mark - Constructor
// ============================================================================

__attribute__((constructor))
static void maxmods_init(void) {
    NSLog(@"[MAXMods] v2.0 debloat loading...");
    loadPrefs();

    // === SESSION FIXES ===
    Class kc = objc_getClass("UICKeyChainStore");
    if (kc) {
        Method cm = class_getClassMethod(kc, @selector(keyChainStoreWithService:accessGroup:));
        if (cm) {
            orig_keyChainStoreWithServiceAccessGroup = method_getImplementation(cm);
            method_setImplementation(cm, (IMP)hook_kcWithService);
        }
        orig_initWithServiceAccessGroup = swizzle(kc,
            @selector(initWithService:accessGroup:), (IMP)hook_kcInitService);
    }
    orig_containerURL = swizzle([NSFileManager class],
        @selector(containerURLForSecurityApplicationGroupIdentifier:), (IMP)hook_containerURL);
    orig_initWithSuiteName = swizzle([NSUserDefaults class],
        @selector(initWithSuiteName:), (IMP)hook_initWithSuiteName);
    NSLog(@"[MAXMods] Session fixes applied");

    // === REMOVE ADS ===
    if (removeAdsEnabled) {
        // Banner fetcher in chat list
        Class bannerFetcher = objc_getClass("InformerBannerFetcher");
        if (bannerFetcher) swizzle(bannerFetcher, @selector(fetchBanners), (IMP)hook_doNothing);

        // Suggested/promoted chats
        Class suggested = objc_getClass("SuggestedChatsProvider");
        if (suggested) swizzle(suggested, @selector(fetchSuggestedChats), (IMP)hook_doNothing);

        NSLog(@"[MAXMods] Ads blocked");
    }

    // === BLOCK TRACKERS ===
    if (blockTrackersEnabled) {
        // MyTracker SDK
        Class myTracker = objc_getClass("MRMyTracker");
        if (myTracker) {
            // Block +[MRMyTracker setupTracker], +[MRMyTracker trackEvent:]
            Method setup = class_getClassMethod(myTracker, @selector(setupTracker));
            if (setup) method_setImplementation(setup, (IMP)hook_doNothing);
            Method track = class_getClassMethod(myTracker, @selector(trackEvent:));
            if (track) method_setImplementation(track, (IMP)hook_doNothing);
        }

        // OKTracer
        Class tracer = objc_getClass("OKTracer");
        if (tracer) {
            Method start = class_getClassMethod(tracer, @selector(start));
            if (start) method_setImplementation(start, (IMP)hook_doNothing);
        }

        // AppTracer SDK
        Class appTracer = objc_getClass("AppTracer");
        if (appTracer) {
            Method init_m = class_getClassMethod(appTracer, @selector(initialize));
            if (init_m) method_setImplementation(init_m, (IMP)hook_doNothing);
        }

        NSLog(@"[MAXMods] Trackers blocked");
    }

    // === SETTINGS UI ===
    Class settingsVC = objc_getClass("_TtC10SettingsUI22SettingsViewController");
    if (settingsVC) {
        class_addMethod(settingsVC, @selector(maxmods_open), (IMP)maxmods_openImp, "v@:");
        orig_settingsVDL = swizzle(settingsVC, @selector(viewDidLoad), (IMP)hook_settingsVDL);
    }
    Class tabBarVC = objc_getClass("_TtC7OMUIKit16TabBarController");
    if (tabBarVC) {
        class_addMethod(tabBarVC, @selector(maxmods_lp:), (IMP)maxmods_lpImp, "v@:@");
        orig_tabBarVDL = swizzle(tabBarVC, @selector(viewDidLoad), (IMP)hook_tabBarVDL);
    }

    NSLog(@"[MAXMods] v2.0 loaded! ads=%d trackers=%d", removeAdsEnabled, blockTrackersEnabled);
}

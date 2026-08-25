/**
 * MAXMods v1.2 — Pure ObjC runtime tweak for MAX messenger (ru.oneme.app)
 * NO CydiaSubstrate dependency.
 *
 * Features:
 * - Session persistence fix (keychain, app group, userdefaults)
 * - Ghost Mode (block read receipts, typing, online)
 * - Anti-Delete messages
 * - Force Save Media
 * - Remove Ads
 * - Settings tab in app settings
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <Security/Security.h>
#import <dlfcn.h>

// ============================================================================
#pragma mark - Settings Storage
// ============================================================================

static NSString *const kGhostKey = @"maxmods.ghostMode";
static NSString *const kAntiDeleteKey = @"maxmods.antiDelete";
static NSString *const kForceSaveKey = @"maxmods.forceSave";
static NSString *const kRemoveAdsKey = @"maxmods.removeAds";

static BOOL ghostModeEnabled = YES;
static BOOL antiDeleteEnabled = YES;
static BOOL forceSaveEnabled = YES;
static BOOL removeAdsEnabled = YES;

static void loadPrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:kGhostKey]) [d setBool:YES forKey:kGhostKey];
    if (![d objectForKey:kAntiDeleteKey]) [d setBool:YES forKey:kAntiDeleteKey];
    if (![d objectForKey:kForceSaveKey]) [d setBool:YES forKey:kForceSaveKey];
    if (![d objectForKey:kRemoveAdsKey]) [d setBool:YES forKey:kRemoveAdsKey];
    ghostModeEnabled = [d boolForKey:kGhostKey];
    antiDeleteEnabled = [d boolForKey:kAntiDeleteKey];
    forceSaveEnabled = [d boolForKey:kForceSaveKey];
    removeAdsEnabled = [d boolForKey:kRemoveAdsKey];
}

static void savePrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:ghostModeEnabled forKey:kGhostKey];
    [d setBool:antiDeleteEnabled forKey:kAntiDeleteKey];
    [d setBool:forceSaveEnabled forKey:kForceSaveKey];
    [d setBool:removeAdsEnabled forKey:kRemoveAdsKey];
    [d synchronize];
}

// ============================================================================
#pragma mark - Swizzle Helper
// ============================================================================

static IMP swizzle(Class cls, SEL sel, IMP newImp) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        NSLog(@"[MAXMods] WARNING: not found: %@ -%@",
              NSStringFromClass(cls), NSStringFromSelector(sel));
        return NULL;
    }
    IMP orig = method_getImplementation(method);
    method_setImplementation(method, newImp);
    return orig;
}

// ============================================================================
#pragma mark - SESSION FIX: Keychain Access Group
// ============================================================================

// Strip kSecAttrAccessGroup from all keychain queries so iOS uses the default
// group (teamID.bundleID from entitlements), which is accessible after re-sign.

typedef OSStatus (*SecItemFunc)(CFDictionaryRef, ...);

static SecItemFunc orig_SecItemCopyMatching = NULL;
static SecItemFunc orig_SecItemAdd = NULL;
static SecItemFunc orig_SecItemUpdate = NULL;
static SecItemFunc orig_SecItemDelete = NULL;

static NSMutableDictionary *stripAccessGroup(CFDictionaryRef query) {
    NSMutableDictionary *m = [(__bridge NSDictionary *)query mutableCopy];
    [m removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    return m;
}

static OSStatus hook_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSMutableDictionary *q = stripAccessGroup(query);
    return orig_SecItemCopyMatching((__bridge CFDictionaryRef)q, result);
}

static OSStatus hook_SecItemAdd(CFDictionaryRef attrs, CFTypeRef *result) {
    NSMutableDictionary *a = stripAccessGroup(attrs);
    return ((OSStatus(*)(CFDictionaryRef,CFTypeRef*))orig_SecItemAdd)((__bridge CFDictionaryRef)a, result);
}

static OSStatus hook_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attrsToUpdate) {
    NSMutableDictionary *q = stripAccessGroup(query);
    return ((OSStatus(*)(CFDictionaryRef,CFDictionaryRef))orig_SecItemUpdate)((__bridge CFDictionaryRef)q, attrsToUpdate);
}

static OSStatus hook_SecItemDelete(CFDictionaryRef query) {
    NSMutableDictionary *q = stripAccessGroup(query);
    return ((OSStatus(*)(CFDictionaryRef))orig_SecItemDelete)((__bridge CFDictionaryRef)q);
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
#pragma mark - Ghost Mode / Anti-Delete / Force Save / Ads (original hooks)
// ============================================================================

static IMP orig_markChat = NULL;
static IMP orig_markChatsAsRead = NULL;
static IMP orig_startTyping = NULL;
static IMP orig_stopTyping = NULL;
static IMP orig_updateOnlineStatus = NULL;
static IMP orig_updateOnlineStatus2 = NULL;
static IMP orig_deleteMessages = NULL;
static IMP orig_processDelete = NULL;
static IMP orig_handleDelete = NULL;

static void hook_markChat(id self, SEL _cmd, id chat, id arg2, id msgId) {
    if (ghostModeEnabled) return;
    if (orig_markChat) ((void(*)(id,SEL,id,id,id))orig_markChat)(self, _cmd, chat, arg2, msgId);
}
static void hook_markChatsAsRead(id self, SEL _cmd, id chats, long long type) {
    if (ghostModeEnabled) return;
    if (orig_markChatsAsRead) ((void(*)(id,SEL,id,long long))orig_markChatsAsRead)(self, _cmd, chats, type);
}
static void hook_startTyping(id self, SEL _cmd, long long type, id chat, id key) {
    if (ghostModeEnabled) return;
    if (orig_startTyping) ((void(*)(id,SEL,long long,id,id))orig_startTyping)(self, _cmd, type, chat, key);
}
static void hook_stopTyping(id self, SEL _cmd, id key) {
    if (ghostModeEnabled) return;
    if (orig_stopTyping) ((void(*)(id,SEL,id))orig_stopTyping)(self, _cmd, key);
}
static void hook_updateOnlineStatus(id self, SEL _cmd) {
    if (ghostModeEnabled) return;
    if (orig_updateOnlineStatus) ((void(*)(id,SEL))orig_updateOnlineStatus)(self, _cmd);
}
static void hook_updateOnlineStatus2(id self, SEL _cmd) {
    if (ghostModeEnabled) return;
    if (orig_updateOnlineStatus2) ((void(*)(id,SEL))orig_updateOnlineStatus2)(self, _cmd);
}
static void hook_deleteMessages(id self, SEL _cmd, id pks, BOOL forAll, BOOL enqueue) {
    if (antiDeleteEnabled) return;
    if (orig_deleteMessages) ((void(*)(id,SEL,id,BOOL,BOOL))orig_deleteMessages)(self, _cmd, pks, forAll, enqueue);
}
static void hook_processDelete(id self, SEL _cmd, id notification) {
    if (antiDeleteEnabled) return;
    if (orig_processDelete) ((void(*)(id,SEL,id))orig_processDelete)(self, _cmd, notification);
}
static void hook_handleDelete(id self, SEL _cmd, id messages, id chat) {
    if (antiDeleteEnabled) return;
    if (orig_handleDelete) ((void(*)(id,SEL,id,id))orig_handleDelete)(self, _cmd, messages, chat);
}
static BOOL hook_returnNO(id self, SEL _cmd) { return NO; }
static BOOL hook_returnYES(id self, SEL _cmd) { return YES; }
static void hook_fetchBanners(id self, SEL _cmd) {
    if (removeAdsEnabled) return;
}

// ============================================================================
#pragma mark - Settings ViewController (MAXMods tab)
// ============================================================================

@interface MAXModsSettingsController : UITableViewController
@end

@implementation MAXModsSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"MAXMods";
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 0);
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
        self.tableView.style == UITableViewStyleGrouped;
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 4 : 1;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return @"Моды";
    return @"Инфо";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (ip.section == 0) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.tag = ip.row;
        [sw addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;

        switch (ip.row) {
            case 0:
                cell.textLabel.text = @"Невидимка (Ghost)";
                sw.on = ghostModeEnabled;
                break;
            case 1:
                cell.textLabel.text = @"Анти-удаление";
                sw.on = antiDeleteEnabled;
                break;
            case 2:
                cell.textLabel.text = @"Скачивание медиа";
                sw.on = forceSaveEnabled;
                break;
            case 3:
                cell.textLabel.text = @"Без рекламы";
                sw.on = removeAdsEnabled;
                break;
        }
    } else {
        cell.textLabel.text = @"MAXMods";
        cell.detailTextLabel.text = @"v1.2";
    }
    return cell;
}

- (void)toggleChanged:(UISwitch *)sw {
    switch (sw.tag) {
        case 0: ghostModeEnabled = sw.on; break;
        case 1: antiDeleteEnabled = sw.on; break;
        case 2: forceSaveEnabled = sw.on; break;
        case 3: removeAdsEnabled = sw.on; break;
    }
    savePrefs();
}

@end

// ============================================================================
#pragma mark - Hook Settings Screen to add MAXMods button
// ============================================================================

static IMP orig_settingsViewDidLoad = NULL;

static void hook_settingsViewDidLoad(id self, SEL _cmd) {
    if (orig_settingsViewDidLoad)
        ((void(*)(id,SEL))orig_settingsViewDidLoad)(self, _cmd);

    // Add a "MAXMods" button to the navigation bar
    UIBarButtonItem *btn = [[UIBarButtonItem alloc]
        initWithTitle:@"Моды"
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(maxmods_openSettings)];
    UIViewController *vc = (UIViewController *)self;
    if (vc.navigationItem.rightBarButtonItems) {
        NSMutableArray *items = [vc.navigationItem.rightBarButtonItems mutableCopy];
        [items addObject:btn];
        vc.navigationItem.rightBarButtonItems = items;
    } else {
        vc.navigationItem.rightBarButtonItem = btn;
    }
}

static void maxmods_openSettingsImp(id self, SEL _cmd) {
    MAXModsSettingsController *modsVC = [[MAXModsSettingsController alloc]
        initWithStyle:UITableViewStyleGrouped];
    UIViewController *vc = (UIViewController *)self;
    [vc.navigationController pushViewController:modsVC animated:YES];
}

// ============================================================================
#pragma mark - Shake gesture (keep as fallback)
// ============================================================================

static IMP orig_motionEnded = NULL;
static void hook_motionEnded(id self, SEL _cmd, UIEventSubtype motion, id event) {
    if (motion == UIEventSubtypeMotionShake) {
        // Open settings via push if possible
        UIWindow *kw = nil;
        for (UIWindowScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (s.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in s.windows) {
                    if (w.isKeyWindow) { kw = w; break; }
                }
            }
        }
        UIViewController *top = kw.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        MAXModsSettingsController *modsVC = [[MAXModsSettingsController alloc]
            initWithStyle:UITableViewStyleGrouped];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:modsVC];
        modsVC.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemDone
            target:modsVC action:@selector(dismissSelf)];
        [top presentViewController:nav animated:YES completion:nil];
        return;
    }
    if (orig_motionEnded) ((void(*)(id,SEL,UIEventSubtype,id))orig_motionEnded)(self, _cmd, motion, event);
}

// Add dismissSelf to MAXModsSettingsController
@implementation MAXModsSettingsController (Dismiss)
- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

// ============================================================================
#pragma mark - Constructor
// ============================================================================

// fishhook-style rebinding for C functions
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>

// Simple rebind using dyld interpose (works without fishhook)
// We use the __attribute__((used, section)) trick for DYLD_INTERPOSE

typedef struct { const void *replacement; const void *replacee; } interpose_t;

__attribute__((used, section("__DATA,__interpose")))
static const interpose_t interpose_SecItemCopyMatching = {
    (const void *)&hook_SecItemCopyMatching,
    (const void *)&SecItemCopyMatching
};

__attribute__((used, section("__DATA,__interpose")))
static const interpose_t interpose_SecItemAdd = {
    (const void *)&hook_SecItemAdd,
    (const void *)&SecItemAdd
};

__attribute__((used, section("__DATA,__interpose")))
static const interpose_t interpose_SecItemUpdate = {
    (const void *)&hook_SecItemUpdate,
    (const void *)&SecItemUpdate
};

__attribute__((used, section("__DATA,__interpose")))
static const interpose_t interpose_SecItemDelete = {
    (const void *)&hook_SecItemDelete,
    (const void *)&SecItemDelete
};

__attribute__((constructor))
static void maxmods_init(void) {
    NSLog(@"[MAXMods] Loading v1.2 (session fix + settings tab)...");
    loadPrefs();

    // Set orig pointers for interposed functions (they call through to real impl)
    orig_SecItemCopyMatching = (SecItemFunc)dlsym(RTLD_NEXT, "SecItemCopyMatching");
    orig_SecItemAdd = (SecItemFunc)dlsym(RTLD_NEXT, "SecItemAdd");
    orig_SecItemUpdate = (SecItemFunc)dlsym(RTLD_NEXT, "SecItemUpdate");
    orig_SecItemDelete = (SecItemFunc)dlsym(RTLD_NEXT, "SecItemDelete");
    NSLog(@"[MAXMods] Keychain hooks: interpose active");

    // App Group Container fix
    orig_containerURL = swizzle([NSFileManager class],
        @selector(containerURLForSecurityApplicationGroupIdentifier:),
        (IMP)hook_containerURL);
    NSLog(@"[MAXMods] Container URL hook: %@", orig_containerURL ? @"OK" : @"SKIP");

    // UserDefaults suite fix
    orig_initWithSuiteName = swizzle([NSUserDefaults class],
        @selector(initWithSuiteName:), (IMP)hook_initWithSuiteName);
    NSLog(@"[MAXMods] UserDefaults suite hook: %@", orig_initWithSuiteName ? @"OK" : @"SKIP");

    // Ghost Mode: read receipts
    Class chatService = objc_getClass("OKMChatService");
    if (chatService) {
        orig_markChat = swizzle(chatService,
            @selector(markChat:asReadTo:messageId:), (IMP)hook_markChat);
        orig_markChatsAsRead = swizzle(chatService,
            @selector(markChatsAsReadWithChats:readType:), (IMP)hook_markChatsAsRead);
        orig_deleteMessages = swizzle(chatService,
            @selector(_deleteMessagesWithPks:deleteForAll:enqueueTasks:), (IMP)hook_deleteMessages);
    }

    // Ghost Mode: typing
    Class typingSender = objc_getClass("OKMChatTypingSender");
    if (typingSender) {
        orig_startTyping = swizzle(typingSender,
            @selector(startSendingTypingWithType:inChat:key:), (IMP)hook_startTyping);
        orig_stopTyping = swizzle(typingSender,
            @selector(stopSendingTypingWithKey:), (IMP)hook_stopTyping);
    }

    // Ghost Mode: online status
    Class onlineStatus = objc_getClass("OKMOnlineStatus");
    if (onlineStatus)
        orig_updateOnlineStatus = swizzle(onlineStatus,
            @selector(updateOnlineStatus), (IMP)hook_updateOnlineStatus);
    Class chatPresenter = objc_getClass("OMChatPresenter");
    if (chatPresenter)
        orig_updateOnlineStatus2 = swizzle(chatPresenter,
            @selector(updateOnlineStatus), (IMP)hook_updateOnlineStatus2);

    // Anti-delete
    Class deleteListener = objc_getClass("OKMMessageDeleteListener");
    if (deleteListener) {
        orig_processDelete = swizzle(deleteListener,
            @selector(processDeleteNotification:), (IMP)hook_processDelete);
        orig_handleDelete = swizzle(deleteListener,
            @selector(handleDeletedMessages:inChat:), (IMP)hook_handleDelete);
    }

    // Force save media
    if (forceSaveEnabled) {
        Class restrictions = objc_getClass("OKMChatRestrictions");
        if (restrictions) {
            swizzle(restrictions, @selector(isNoForward), (IMP)hook_returnNO);
            swizzle(restrictions, @selector(noForward), (IMP)hook_returnNO);
            swizzle(restrictions, @selector(shouldRestrictRecordForAll), (IMP)hook_returnNO);
        }
        Class restInfo = objc_getClass("OKMRestrictionsInfo");
        if (restInfo) {
            swizzle(restInfo, @selector(isNoForward), (IMP)hook_returnNO);
            swizzle(restInfo, @selector(noForward), (IMP)hook_returnNO);
        }
        unsigned int count = 0;
        Class *all = objc_copyClassList(&count);
        for (unsigned int i = 0; i < count; i++) {
            if (class_getInstanceMethod(all[i], @selector(allowSaveToGallery)))
                swizzle(all[i], @selector(allowSaveToGallery), (IMP)hook_returnYES);
            if (class_getInstanceMethod(all[i], @selector(allowDownload)))
                swizzle(all[i], @selector(allowDownload), (IMP)hook_returnYES);
        }
        free(all);
    }

    // Remove ads
    Class bannerFetcher = objc_getClass("InformerBannerFetcher");
    if (bannerFetcher)
        swizzle(bannerFetcher, @selector(fetchBanners), (IMP)hook_fetchBanners);

    // Settings tab: hook SettingsViewController viewDidLoad
    Class settingsVC = objc_getClass("_TtC10SettingsUI22SettingsViewController");
    if (settingsVC) {
        // Add the maxmods_openSettings method to the class
        class_addMethod(settingsVC, @selector(maxmods_openSettings),
            (IMP)maxmods_openSettingsImp, "v@:");
        orig_settingsViewDidLoad = swizzle(settingsVC,
            @selector(viewDidLoad), (IMP)hook_settingsViewDidLoad);
        NSLog(@"[MAXMods] Settings tab hook: OK");
    } else {
        NSLog(@"[MAXMods] Settings VC not found, using shake only");
    }

    // Shake gesture (fallback)
    orig_motionEnded = swizzle([UIWindow class],
        @selector(motionEnded:withEvent:), (IMP)hook_motionEnded);

    NSLog(@"[MAXMods] Loaded! ghost=%d anti-del=%d save=%d no-ads=%d",
        ghostModeEnabled, antiDeleteEnabled, forceSaveEnabled, removeAdsEnabled);
}


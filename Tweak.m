/**
 * MAXMods — Pure ObjC runtime tweak for MAX messenger (ru.oneme.app)
 * NO CydiaSubstrate dependency — uses method_exchangeImplementations directly.
 * Features: Ghost Mode, Anti-Delete, Force Save Media, Remove Ads
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================================
#pragma mark - Settings
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
        NSLog(@"[MAXMods] WARNING: method not found: %@ -%@",
              NSStringFromClass(cls), NSStringFromSelector(sel));
        return NULL;
    }
    IMP origImp = method_getImplementation(method);
    method_setImplementation(method, newImp);
    return origImp;
}

// ============================================================================
#pragma mark - Original IMPs (saved for calling through)
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

// ============================================================================
#pragma mark - Ghost Mode Hooks
// ============================================================================

// Block read receipts
static void hook_markChat(id self, SEL _cmd, id chat, id arg2, id msgId) {
    if (ghostModeEnabled) {
        NSLog(@"[MAXMods] Ghost: blocked read receipt");
        return;
    }
    if (orig_markChat) ((void(*)(id,SEL,id,id,id))orig_markChat)(self, _cmd, chat, arg2, msgId);
}

static void hook_markChatsAsRead(id self, SEL _cmd, id chats, long long type) {
    if (ghostModeEnabled) {
        NSLog(@"[MAXMods] Ghost: blocked bulk read mark");
        return;
    }
    if (orig_markChatsAsRead) ((void(*)(id,SEL,id,long long))orig_markChatsAsRead)(self, _cmd, chats, type);
}

// Block typing indicators
static void hook_startTyping(id self, SEL _cmd, long long type, id chat, id key) {
    if (ghostModeEnabled) {
        NSLog(@"[MAXMods] Ghost: blocked typing");
        return;
    }
    if (orig_startTyping) ((void(*)(id,SEL,long long,id,id))orig_startTyping)(self, _cmd, type, chat, key);
}

static void hook_stopTyping(id self, SEL _cmd, id key) {
    if (ghostModeEnabled) return;
    if (orig_stopTyping) ((void(*)(id,SEL,id))orig_stopTyping)(self, _cmd, key);
}

// Block online status
static void hook_updateOnlineStatus(id self, SEL _cmd) {
    if (ghostModeEnabled) {
        NSLog(@"[MAXMods] Ghost: blocked online status");
        return;
    }
    if (orig_updateOnlineStatus) ((void(*)(id,SEL))orig_updateOnlineStatus)(self, _cmd);
}

static void hook_updateOnlineStatus2(id self, SEL _cmd) {
    if (ghostModeEnabled) return;
    if (orig_updateOnlineStatus2) ((void(*)(id,SEL))orig_updateOnlineStatus2)(self, _cmd);
}

// ============================================================================
#pragma mark - Anti-Delete Hooks
// ============================================================================

static void hook_deleteMessages(id self, SEL _cmd, id pks, BOOL forAll, BOOL enqueue) {
    if (antiDeleteEnabled) {
        NSLog(@"[MAXMods] Anti-delete: blocked message deletion");
        return;
    }
    if (orig_deleteMessages) ((void(*)(id,SEL,id,BOOL,BOOL))orig_deleteMessages)(self, _cmd, pks, forAll, enqueue);
}

static void hook_processDelete(id self, SEL _cmd, id notification) {
    if (antiDeleteEnabled) {
        NSLog(@"[MAXMods] Anti-delete: blocked delete notification");
        return;
    }
    if (orig_processDelete) ((void(*)(id,SEL,id))orig_processDelete)(self, _cmd, notification);
}

static void hook_handleDelete(id self, SEL _cmd, id messages, id chat) {
    if (antiDeleteEnabled) {
        NSLog(@"[MAXMods] Anti-delete: blocked handleDeletedMessages");
        return;
    }
    if (orig_handleDelete) ((void(*)(id,SEL,id,id))orig_handleDelete)(self, _cmd, messages, chat);
}

// ============================================================================
#pragma mark - Force Save / Remove Restrictions
// ============================================================================

static BOOL hook_returnNO(id self, SEL _cmd) {
    return NO;
}

static BOOL hook_returnYES(id self, SEL _cmd) {
    return YES;
}

// ============================================================================
#pragma mark - Remove Ads
// ============================================================================

static void hook_fetchBanners(id self, SEL _cmd) {
    if (removeAdsEnabled) {
        NSLog(@"[MAXMods] Ads: blocked banner fetch");
        return;
    }
}

// ============================================================================
#pragma mark - Settings UI
// ============================================================================

static void showSettings(void) {
    loadPrefs();
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"MAXMods v1.1"
        message:@"Настройки модов"
        preferredStyle:UIAlertControllerStyleAlert];

    NSString *t1 = [NSString stringWithFormat:@"%@ Невидимка",
        ghostModeEnabled ? @"✅" : @"❌"];
    [alert addAction:[UIAlertAction actionWithTitle:t1
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            ghostModeEnabled = !ghostModeEnabled; savePrefs(); showSettings();
        }]];

    NSString *t2 = [NSString stringWithFormat:@"%@ Анти-удаление",
        antiDeleteEnabled ? @"✅" : @"❌"];
    [alert addAction:[UIAlertAction actionWithTitle:t2
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            antiDeleteEnabled = !antiDeleteEnabled; savePrefs(); showSettings();
        }]];

    NSString *t3 = [NSString stringWithFormat:@"%@ Скачивание медиа",
        forceSaveEnabled ? @"✅" : @"❌"];
    [alert addAction:[UIAlertAction actionWithTitle:t3
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            forceSaveEnabled = !forceSaveEnabled; savePrefs(); showSettings();
        }]];

    NSString *t4 = [NSString stringWithFormat:@"%@ Без рекламы",
        removeAdsEnabled ? @"✅" : @"❌"];
    [alert addAction:[UIAlertAction actionWithTitle:t4
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            removeAdsEnabled = !removeAdsEnabled; savePrefs(); showSettings();
        }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Закрыть"
        style:UIAlertActionStyleCancel handler:nil]];

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = nil;
        for (UIWindowScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (s.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in s.windows) {
                    if (w.isKeyWindow) { kw = w; break; }
                }
            }
        }
        UIViewController *vc = kw.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

// Shake gesture hook
static IMP orig_motionEnded = NULL;
static void hook_motionEnded(id self, SEL _cmd, UIEventSubtype motion, id event) {
    if (motion == UIEventSubtypeMotionShake) {
        showSettings();
        return;
    }
    if (orig_motionEnded) ((void(*)(id,SEL,UIEventSubtype,id))orig_motionEnded)(self, _cmd, motion, event);
}

// ============================================================================
#pragma mark - Constructor
// ============================================================================

__attribute__((constructor))
static void maxmods_init(void) {
    NSLog(@"[MAXMods] Loading tweak v1.1 (no-substrate)...");
    loadPrefs();

    // Ghost Mode: read receipts
    Class chatService = objc_getClass("OKMChatService");
    if (chatService) {
        orig_markChat = swizzle(chatService,
            @selector(markChat:asReadTo:messageId:), (IMP)hook_markChat);
        orig_markChatsAsRead = swizzle(chatService,
            @selector(markChatsAsReadWithChats:readType:), (IMP)hook_markChatsAsRead);
        orig_deleteMessages = swizzle(chatService,
            @selector(_deleteMessagesWithPks:deleteForAll:enqueueTasks:), (IMP)hook_deleteMessages);
        NSLog(@"[MAXMods] Hooked OKMChatService");
    }

    // Ghost Mode: typing
    Class typingSender = objc_getClass("OKMChatTypingSender");
    if (typingSender) {
        orig_startTyping = swizzle(typingSender,
            @selector(startSendingTypingWithType:inChat:key:), (IMP)hook_startTyping);
        orig_stopTyping = swizzle(typingSender,
            @selector(stopSendingTypingWithKey:), (IMP)hook_stopTyping);
        NSLog(@"[MAXMods] Hooked OKMChatTypingSender");
    }

    // Ghost Mode: online status
    Class onlineStatus = objc_getClass("OKMOnlineStatus");
    if (onlineStatus) {
        orig_updateOnlineStatus = swizzle(onlineStatus,
            @selector(updateOnlineStatus), (IMP)hook_updateOnlineStatus);
        NSLog(@"[MAXMods] Hooked OKMOnlineStatus");
    }
    Class chatPresenter = objc_getClass("OMChatPresenter");
    if (chatPresenter) {
        orig_updateOnlineStatus2 = swizzle(chatPresenter,
            @selector(updateOnlineStatus), (IMP)hook_updateOnlineStatus2);
        NSLog(@"[MAXMods] Hooked OMChatPresenter");
    }

    // Anti-delete
    Class deleteListener = objc_getClass("OKMMessageDeleteListener");
    if (deleteListener) {
        orig_processDelete = swizzle(deleteListener,
            @selector(processDeleteNotification:), (IMP)hook_processDelete);
        orig_handleDelete = swizzle(deleteListener,
            @selector(handleDeletedMessages:inChat:), (IMP)hook_handleDelete);
        NSLog(@"[MAXMods] Hooked OKMMessageDeleteListener");
    }

    // Force save media
    if (forceSaveEnabled) {
        Class restrictions = objc_getClass("OKMChatRestrictions");
        if (restrictions) {
            swizzle(restrictions, @selector(isNoForward), (IMP)hook_returnNO);
            swizzle(restrictions, @selector(noForward), (IMP)hook_returnNO);
            swizzle(restrictions, @selector(shouldRestrictRecordForAll), (IMP)hook_returnNO);
            NSLog(@"[MAXMods] Hooked OKMChatRestrictions");
        }
        Class restInfo = objc_getClass("OKMRestrictionsInfo");
        if (restInfo) {
            swizzle(restInfo, @selector(isNoForward), (IMP)hook_returnNO);
            swizzle(restInfo, @selector(noForward), (IMP)hook_returnNO);
        }
        // Hook allowSaveToGallery/allowDownload on any class that has them
        unsigned int count = 0;
        Class *allClasses = objc_copyClassList(&count);
        for (unsigned int i = 0; i < count; i++) {
            Class c = allClasses[i];
            if (class_getInstanceMethod(c, @selector(allowSaveToGallery)))
                swizzle(c, @selector(allowSaveToGallery), (IMP)hook_returnYES);
            if (class_getInstanceMethod(c, @selector(allowDownload)))
                swizzle(c, @selector(allowDownload), (IMP)hook_returnYES);
            if (class_getInstanceMethod(c, @selector(allowForward)))
                swizzle(c, @selector(allowForward), (IMP)hook_returnYES);
        }
        free(allClasses);
        NSLog(@"[MAXMods] Force-save hooks applied");
    }

    // Remove ads
    Class bannerFetcher = objc_getClass("InformerBannerFetcher");
    if (bannerFetcher) {
        swizzle(bannerFetcher, @selector(fetchBanners), (IMP)hook_fetchBanners);
        NSLog(@"[MAXMods] Hooked InformerBannerFetcher");
    }

    // Shake gesture
    orig_motionEnded = swizzle([UIWindow class],
        @selector(motionEnded:withEvent:), (IMP)hook_motionEnded);

    NSLog(@"[MAXMods] Loaded! ghost=%d anti-del=%d save=%d no-ads=%d",
        ghostModeEnabled, antiDeleteEnabled, forceSaveEnabled, removeAdsEnabled);
}


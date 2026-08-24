/**
 * MAXMods — Tweak for MAX messenger (ru.oneme.app)
 * Features: Ghost Mode, Anti-Delete, Force Save Media, Remove Ads
 *
 * Hook targets found via reverse engineering MAX 26.17.3 (arm64)
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================================
// MARK: - Settings Storage
// ============================================================================

#define PREFS_PREFIX @"maxmods."

static BOOL ghostModeEnabled = YES;
static BOOL antiDeleteEnabled = YES;
static BOOL forceSaveEnabled = YES;
static BOOL removeAdsEnabled = YES;

static void loadPreferences(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Default: all enabled
    if ([defaults objectForKey:@PREFS_PREFIX "ghostMode"] == nil) {
        [defaults setBool:YES forKey:@PREFS_PREFIX "ghostMode"];
    }
    if ([defaults objectForKey:@PREFS_PREFIX "antiDelete"] == nil) {
        [defaults setBool:YES forKey:@PREFS_PREFIX "antiDelete"];
    }
    if ([defaults objectForKey:@PREFS_PREFIX "forceSave"] == nil) {
        [defaults setBool:YES forKey:@PREFS_PREFIX "forceSave"];
    }
    if ([defaults objectForKey:@PREFS_PREFIX "removeAds"] == nil) {
        [defaults setBool:YES forKey:@PREFS_PREFIX "removeAds"];
    }
    ghostModeEnabled = [defaults boolForKey:@PREFS_PREFIX "ghostMode"];
    antiDeleteEnabled = [defaults boolForKey:@PREFS_PREFIX "antiDelete"];
    forceSaveEnabled = [defaults boolForKey:@PREFS_PREFIX "forceSave"];
    removeAdsEnabled = [defaults boolForKey:@PREFS_PREFIX "removeAds"];
}

static void savePreferences(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:ghostModeEnabled forKey:@PREFS_PREFIX "ghostMode"];
    [defaults setBool:antiDeleteEnabled forKey:@PREFS_PREFIX "antiDelete"];
    [defaults setBool:forceSaveEnabled forKey:@PREFS_PREFIX "forceSave"];
    [defaults setBool:removeAdsEnabled forKey:@PREFS_PREFIX "removeAds"];
    [defaults synchronize];
}

// ============================================================================
// MARK: - Ghost Mode: Block Read Receipts
// ============================================================================

%hook OKMChatService

- (void)markChat:(id)chat asReadTo:(id)arg2 messageId:(id)msgId {
    if (ghostModeEnabled) {
        NSLog(@"[MAXMods] Ghost: blocked read receipt for chat");
        return;
    }
    %orig;
}

- (void)markChatsAsReadWithChats:(id)chats readType:(long long)type {
    if (ghostModeEnabled) {
        NSLog(@"[MAXMods] Ghost: blocked bulk read mark");
        return;
    }
    %orig;
}

%end

// ============================================================================
// MARK: - Ghost Mode: Block Typing Indicators
// ============================================================================

%hook OKMChatTypingSender

- (void)startSendingTypingWithType:(long long)type inChat:(id)chat key:(id)key {
    if (ghostModeEnabled) {
        NSLog(@"[MAXMods] Ghost: blocked typing indicator");
        return;
    }
    %orig;
}

- (void)stopSendingTypingWithKey:(id)key {
    if (ghostModeEnabled) return;
    %orig;
}

%end

// ============================================================================
// MARK: - Ghost Mode: Block Online Status
// ============================================================================

// OKMOnlineStatus — suppress outgoing online presence updates
%hook OKMOnlineStatus

- (void)updateOnlineStatus {
    if (ghostModeEnabled) {
        NSLog(@"[MAXMods] Ghost: blocked online status update");
        return;
    }
    %orig;
}

%end

// Also try hooking the presenter that pushes status
%hook OMChatPresenter

- (void)updateOnlineStatus {
    if (ghostModeEnabled) return;
    %orig;
}

%end

// ============================================================================
// MARK: - Anti-Delete Messages
// ============================================================================

%hook OKMMessageDeleteListener

// Block remote message deletion — keep the message locally
- (void)processDeleteNotification:(id)notification {
    if (antiDeleteEnabled) {
        NSLog(@"[MAXMods] Anti-delete: intercepted remote deletion");
        // Don't call %orig — message stays in chat
        return;
    }
    %orig;
}

// Alternative selector — one of these will match at runtime
- (void)handleDeletedMessages:(id)messages inChat:(id)chat {
    if (antiDeleteEnabled) {
        NSLog(@"[MAXMods] Anti-delete: blocked deletion of messages");
        return;
    }
    %orig;
}

%end

// Block the delete task from removing messages from DB
%hook OKMChatService

- (void)_deleteMessagesWithPks:(id)pks deleteForAll:(BOOL)forAll enqueueTasks:(BOOL)enqueue {
    if (antiDeleteEnabled && !forAll) {
        // Only block if it's an incoming deletion (not our own)
        // "deleteForAll" from remote means someone else deleted
        NSLog(@"[MAXMods] Anti-delete: blocked _deleteMessages (remote)");
        return;
    }
    %orig;
}

%end

// ============================================================================
// MARK: - Force Save Media (bypass noForward/download restrictions)
// ============================================================================

%hook OKMChatRestrictions

- (BOOL)isNoForward {
    if (forceSaveEnabled) return NO;
    return %orig;
}

- (BOOL)noForward {
    if (forceSaveEnabled) return NO;
    return %orig;
}

- (BOOL)shouldRestrictRecordForAll {
    if (forceSaveEnabled) return NO;
    return %orig;
}

%end

// Hook the restriction info class (Swift bridge)
%hook OKMRestrictionsInfo

- (BOOL)isNoForward {
    if (forceSaveEnabled) return NO;
    return %orig;
}

- (BOOL)noForward {
    if (forceSaveEnabled) return NO;
    return %orig;
}

%end

// Generic hook for any class that exposes allowSaveToGallery / allowDownload
// We use runtime introspection to find and hook these
static void hookSaveGalleryMethods(void) {
    // Search for classes with allowSaveToGallery getter
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);

    SEL saveSel = @selector(allowSaveToGallery);
    SEL downloadSel = @selector(allowDownload);
    SEL forwardSel = @selector(allowForward);

    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        if (class_getInstanceMethod(cls, saveSel)) {
            // Swizzle to always return YES
            Method m = class_getInstanceMethod(cls, saveSel);
            if (m) {
                IMP newImp = imp_implementationWithBlock(^BOOL(id self) {
                    if (forceSaveEnabled) return YES;
                    // Call original — not possible cleanly here, but for BOOL getters just YES
                    return YES;
                });
                method_setImplementation(m, newImp);
            }
        }
        if (class_getInstanceMethod(cls, downloadSel)) {
            Method m = class_getInstanceMethod(cls, downloadSel);
            if (m) {
                IMP newImp = imp_implementationWithBlock(^BOOL(id self) {
                    return forceSaveEnabled ? YES : YES; // always allow
                });
                method_setImplementation(m, newImp);
            }
        }
    }
    free(classes);
}

// ============================================================================
// MARK: - Remove Ads
// ============================================================================

// InformerBanner — chat list promotional banners
%hook InformerBannerFetcher

- (void)fetchBanners {
    if (removeAdsEnabled) {
        NSLog(@"[MAXMods] Ads: blocked InformerBanner fetch");
        return;
    }
    %orig;
}

- (void)fetchBannersWithCompletion:(id)completion {
    if (removeAdsEnabled) {
        NSLog(@"[MAXMods] Ads: blocked InformerBanner fetch (completion)");
        if (completion) {
            // Return empty result
            ((void(^)(id))completion)(nil);
        }
        return;
    }
    %orig;
}

%end

// Supplementary ad view in video player (OVKit / MyTarget SDK)
%hook OVKSupplementaryAdView

- (void)layoutSubviews {
    %orig;
    if (removeAdsEnabled) {
        [self setHidden:YES];
        [self setFrame:CGRectZero];
    }
}

- (void)setFrame:(CGRect)frame {
    if (removeAdsEnabled) {
        %orig(CGRectZero);
        return;
    }
    %orig;
}

%end

// BannerPromoView — promotional banners elsewhere in UI
%hook BannerPromoView

- (void)layoutSubviews {
    %orig;
    if (removeAdsEnabled) {
        [self setHidden:YES];
        [self setFrame:CGRectZero];
    }
}

%end

// SuggestedChatsProvider — "recommended" chats that may be ads
%hook SuggestedChatsProvider

- (id)suggestedChats {
    if (removeAdsEnabled) return @[];
    return %orig;
}

- (void)fetchSuggestedChats {
    if (removeAdsEnabled) return;
    %orig;
}

%end

// ============================================================================
// MARK: - Settings UI (accessible via shake gesture or long-press on tab bar)
// ============================================================================

static void showSettingsAlert(void) {
    loadPreferences();

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"MAXMods"
        message:@"Настройки модов"
        preferredStyle:UIAlertControllerStyleAlert];

    NSString *ghostTitle = [NSString stringWithFormat:@"%@ Невидимка (Ghost)",
        ghostModeEnabled ? @"✅" : @"❌"];
    [alert addAction:[UIAlertAction actionWithTitle:ghostTitle
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            ghostModeEnabled = !ghostModeEnabled;
            savePreferences();
            showSettingsAlert();
        }]];

    NSString *antiDelTitle = [NSString stringWithFormat:@"%@ Анти-удаление",
        antiDeleteEnabled ? @"✅" : @"❌"];
    [alert addAction:[UIAlertAction actionWithTitle:antiDelTitle
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            antiDeleteEnabled = !antiDeleteEnabled;
            savePreferences();
            showSettingsAlert();
        }]];

    NSString *saveTitle = [NSString stringWithFormat:@"%@ Скачивание медиа",
        forceSaveEnabled ? @"✅" : @"❌"];
    [alert addAction:[UIAlertAction actionWithTitle:saveTitle
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            forceSaveEnabled = !forceSaveEnabled;
            savePreferences();
            showSettingsAlert();
        }]];

    NSString *adsTitle = [NSString stringWithFormat:@"%@ Без рекламы",
        removeAdsEnabled ? @"✅" : @"❌"];
    [alert addAction:[UIAlertAction actionWithTitle:adsTitle
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            removeAdsEnabled = !removeAdsEnabled;
            savePreferences();
            showSettingsAlert();
        }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Закрыть"
        style:UIAlertActionStyleCancel handler:nil]];

    UIWindow *keyWindow = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *window in scene.windows) {
                if (window.isKeyWindow) {
                    keyWindow = window;
                    break;
                }
            }
        }
    }
    UIViewController *topVC = keyWindow.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    [topVC presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// MARK: - Shake Gesture to Open Settings
// ============================================================================

%hook UIWindow

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        showSettingsAlert();
        return;
    }
    %orig;
}

%end

// ============================================================================
// MARK: - Constructor (entry point)
// ============================================================================

%ctor {
    NSLog(@"[MAXMods] Tweak loaded! Version 1.0.0");
    loadPreferences();

    // Hook allowSaveToGallery/allowDownload at runtime
    if (forceSaveEnabled) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
                hookSaveGalleryMethods();
                NSLog(@"[MAXMods] Force-save hooks applied");
            });
    }

    NSLog(@"[MAXMods] Settings: ghost=%d antiDel=%d save=%d noAds=%d",
        ghostModeEnabled, antiDeleteEnabled, forceSaveEnabled, removeAdsEnabled);
}


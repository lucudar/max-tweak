/**
 * MAXMods v2.3 — Fixed keychain hook (only strip ORIGINAL team's access group)
 *
 * Problem: v2.2 stripped ALL access groups to nil, including valid ones.
 * Fix: Only strip when the group contains the original team ID "6T4347P359"
 * which is inaccessible after re-sign. Leave all other groups untouched.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// The original team ID that's hardcoded in the binary but inaccessible after re-sign
static NSString *const kOriginalTeamID = @"6T4347P359";

static IMP orig_kcClass = NULL;
static IMP orig_kcInit = NULL;

static id hook_kcClass(id self, SEL _cmd, id service, NSString *group) {
    // Only strip if it's the original team's group that we can't access
    if (group && [group containsString:kOriginalTeamID]) {
        NSLog(@"[MAXMods] Keychain: stripped inaccessible group: %@", group);
        return ((id(*)(id,SEL,id,id))orig_kcClass)(self, _cmd, service, nil);
    }
    return ((id(*)(id,SEL,id,id))orig_kcClass)(self, _cmd, service, group);
}

static id hook_kcInit(id self, SEL _cmd, id service, NSString *group) {
    if (group && [group containsString:kOriginalTeamID]) {
        NSLog(@"[MAXMods] Keychain: stripped inaccessible group: %@", group);
        return ((id(*)(id,SEL,id,id))orig_kcInit)(self, _cmd, service, nil);
    }
    return ((id(*)(id,SEL,id,id))orig_kcInit)(self, _cmd, service, group);
}

__attribute__((constructor))
static void maxmods_init(void) {
    NSLog(@"[MAXMods] v2.3 loading (selective keychain fix)...");

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
        NSLog(@"[MAXMods] Keychain fix: selective (only strips %@.* groups)", kOriginalTeamID);
    }

    NSLog(@"[MAXMods] Loaded OK");
}

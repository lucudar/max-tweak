/**
 * MAXMods v2.2 — Keychain-only test
 * ONLY fixes keychain access group. No other hooks.
 * Testing if containerURL or initWithSuiteName causes the delete hang.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static IMP orig_kcClass = NULL;
static IMP orig_kcInit = NULL;

static id hook_kcClass(id self, SEL _cmd, id service, id group) {
    return ((id(*)(id,SEL,id,id))orig_kcClass)(self, _cmd, service, nil);
}
static id hook_kcInit(id self, SEL _cmd, id service, id group) {
    return ((id(*)(id,SEL,id,id))orig_kcInit)(self, _cmd, service, nil);
}

__attribute__((constructor))
static void maxmods_init(void) {
    NSLog(@"[MAXMods] v2.2 keychain-only test");

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
        NSLog(@"[MAXMods] Keychain fix applied");
    }

    NSLog(@"[MAXMods] Loaded (keychain only — no container/defaults hooks)");
}

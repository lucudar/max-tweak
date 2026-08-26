/**
 * MAXMods v2.1 — MINIMAL: only keychain fix to test delete
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

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
#pragma mark - SESSION FIX: Keychain only
// ============================================================================

static IMP orig_kcClass = NULL;
static IMP orig_kcInit = NULL;

static id hook_kcClass(id self, SEL _cmd, id service, id group) {
    return ((id(*)(id,SEL,id,id))orig_kcClass)(self, _cmd, service, nil);
}
static id hook_kcInit(id self, SEL _cmd, id service, id group) {
    return ((id(*)(id,SEL,id,id))orig_kcInit)(self, _cmd, service, nil);
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
#pragma mark - SESSION FIX: NSUserDefaults Suite (SAFE version)
// ============================================================================

// Instead of returning standardUserDefaults (breaks callers expecting a new instance),
// create a REAL NSUserDefaults with the suite but using a mapped name
static IMP orig_initWithSuiteName = NULL;

static id hook_initWithSuiteName(id self, SEL _cmd, NSString *name) {
    if (name && [name isEqualToString:@"group.ru.oneme.app"]) {
        // Redirect to a local suite name that actually works
        return ((id(*)(id,SEL,NSString*))orig_initWithSuiteName)(self, _cmd, @"ru.oneme.app.local");
    }
    return ((id(*)(id,SEL,NSString*))orig_initWithSuiteName)(self, _cmd, name);
}

// ============================================================================
#pragma mark - Constructor
// ============================================================================

__attribute__((constructor))
static void maxmods_init(void) {
    NSLog(@"[MAXMods] v2.1 minimal loading...");

    // Keychain fix
    Class kc = objc_getClass("UICKeyChainStore");
    if (kc) {
        Method cm = class_getClassMethod(kc, @selector(keyChainStoreWithService:accessGroup:));
        if (cm) {
            orig_kcClass = method_getImplementation(cm);
            method_setImplementation(cm, (IMP)hook_kcClass);
        }
        orig_kcInit = swizzle(kc, @selector(initWithService:accessGroup:), (IMP)hook_kcInit);
        NSLog(@"[MAXMods] Keychain fix: OK");
    }

    // Container fix
    orig_containerURL = swizzle([NSFileManager class],
        @selector(containerURLForSecurityApplicationGroupIdentifier:), (IMP)hook_containerURL);
    NSLog(@"[MAXMods] Container fix: OK");

    // UserDefaults fix (safe version - redirect suite name, don't return singleton)
    orig_initWithSuiteName = swizzle([NSUserDefaults class],
        @selector(initWithSuiteName:), (IMP)hook_initWithSuiteName);
    NSLog(@"[MAXMods] UserDefaults fix: OK");

    NSLog(@"[MAXMods] v2.1 loaded (minimal - testing delete)");
}

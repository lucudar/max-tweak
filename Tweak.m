/**
 * MAXMods v3.0 — iOS 27 compatibility fix + session persistence
 *
 * iOS 27 beta has a bug where UICollectionView updates during context menu
 * dismissal cause a deadlock/freeze. This affects the "Delete" action.
 * Fix: delay the delete operation by 0.4s to let the menu dismiss first.
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
#pragma mark - iOS 27 Fix: Delay delete after context menu dismiss
// ============================================================================

static IMP orig_deleteMessage = NULL;

static void hook_deleteMessage(id self, SEL _cmd, id message, id context) {
    // Delay the delete to let context menu dismiss animation complete
    // This fixes the freeze on iOS 27 beta where UICollectionView update
    // during context menu dismissal causes a deadlock
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            ((void(*)(id,SEL,id,id))orig_deleteMessage)(self, _cmd, message, context);
        });
}

// Also fix _unreadMessage which has the same pattern (mark unread from context menu)
static IMP orig_unreadMessage = NULL;

static void hook_unreadMessage(id self, SEL _cmd, id message) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            ((void(*)(id,SEL,id))orig_unreadMessage)(self, _cmd, message);
        });
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
    NSLog(@"[MAXMods] v3.0 loading (iOS 27 fix + session)...");

    // iOS 27 context menu fix
    Class actionProcessor = objc_getClass("OMMessageActionProcessor");
    if (actionProcessor) {
        orig_deleteMessage = swizzle(actionProcessor,
            @selector(_deleteMessage:context:), (IMP)hook_deleteMessage);
        orig_unreadMessage = swizzle(actionProcessor,
            @selector(_unreadMessage:), (IMP)hook_unreadMessage);
        NSLog(@"[MAXMods] iOS 27 fix: delayed delete/unread actions");
    }

    // Keychain fix
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
        NSLog(@"[MAXMods] Keychain fix: OK");
    }

    // Container fix
    orig_containerURL = swizzle([NSFileManager class],
        @selector(containerURLForSecurityApplicationGroupIdentifier:),
        (IMP)hook_containerURL);

    // UserDefaults fix
    orig_initSuite = swizzle([NSUserDefaults class],
        @selector(initWithSuiteName:), (IMP)hook_initSuite);

    NSLog(@"[MAXMods] v3.0 loaded OK");
}

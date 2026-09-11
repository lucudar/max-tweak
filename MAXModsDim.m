/**
 * MAXModsDim.m — v6.6: reliable dimming of messages marked by the
 * two-phase delete (keep-deleted, mod.del).
 *
 * Why the v6.5 implementation never dimmed anything:
 *
 *  1. It swizzled -applyLayoutAttributes: obtained with
 *     class_getInstanceMethod(MessageCell, ...). The Swift MessageCell does
 *     not implement that method, so the returned Method belongs to
 *     UICollectionViewCell — method_setImplementation then replaced the
 *     implementation for EVERY collection-view cell in the app, while the
 *     cell's own layoutSubviews (which runs afterwards) re-applied the
 *     normal appearance.
 *  2. The message object was resolved only through valueForKey:@"message"
 *     and @"viewModel.message". MAX's cell exposes neither key, so KVC threw
 *     NSUnknownKeyException, the @try swallowed it, and alpha was never set.
 *  3. Identity was a single primaryKey string. The delete path
 *     (OMMessageActionProcessor) and the cell path hold different wrapper
 *     objects, so even a successful lookup usually produced a different
 *     string and never matched the marked set.
 *  4. [set containsObject:nil] raises — another silent abort of the block.
 *  5. After marking, only rootViewController.view received setNeedsLayout,
 *     which does not re-lay out already visible cells.
 *
 * This file fixes all of that and deliberately lives next to Tweak.m so the
 * v6.5 code path stays untouched (its hook is harmless: it throws for every
 * foreign cell and is caught). Dimming is applied to contentView.alpha at
 * the end of layoutSubviews, i.e. after anything else that touches the cell.
 *
 * Marked keys are read from the same NSUserDefaults key that Tweak.m writes
 * ("mod.markedDeleted"), so the two-phase delete logic itself is unchanged.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kMAXMarkedKey = @"mod.markedDeleted";
static CGFloat const kMAXDimAlpha = 0.45;

// ============================================================================
#pragma mark - Logging (same file as Tweak.m's maxlog)
// ============================================================================

static void dimlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void dimlog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"[MAXMods/dim] %@", msg);

    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) return;
    NSString *path = [docs stringByAppendingPathComponent:@"maxmods_log.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path])
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    NSString *line = [NSString stringWithFormat:@"%@ | dim: %@\n", [NSDate date], msg];
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

// ============================================================================
#pragma mark - Marked set (cached read of mod.markedDeleted)
// ============================================================================

static NSSet<NSString *> *g_dimMarked = nil;
static NSTimeInterval g_dimMarkedStamp = 0;

static void max_dimInvalidateMarked(void) {
    g_dimMarkedStamp = 0;
}

static NSSet<NSString *> *max_dimMarkedSet(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (g_dimMarked && (now - g_dimMarkedStamp) < 0.25) return g_dimMarked;
    NSArray *saved = [[NSUserDefaults standardUserDefaults]
        stringArrayForKey:kMAXMarkedKey];
    NSMutableSet *set = [NSMutableSet setWithCapacity:saved.count];
    for (id item in saved) {
        if (![item isKindOfClass:[NSString class]]) continue;
        NSString *s = (NSString *)item;
        if (s.length == 0 || [s isEqualToString:@"(null)"]) continue;
        [set addObject:s];
    }
    g_dimMarked = set;
    g_dimMarkedStamp = now;
    return g_dimMarked;
}

// ============================================================================
#pragma mark - Message identity: a set of candidate keys, not one string
//
// The delete path stores whatever "%@" of primaryKey produced. The cell holds
// a different object (view model / render model), so we collect every
// plausible identifier it can give us and treat a hit on any of them as a
// match.
// ============================================================================

static NSArray<NSString *> *max_dimIdSelectorNames(void) {
    static NSArray *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[ @"primaryKey", @"messageId", @"messageID", @"serverId",
                   @"serverID", @"localId", @"localID", @"identifier",
                   @"cid", @"messageCid", @"id", @"time" ];
    });
    return names;
}

// Safe read of a zero-argument getter, honouring its real return type.
static NSString *max_dimStringValue(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = nil;
    @try { sig = [obj methodSignatureForSelector:sel]; }
    @catch (NSException *e) { return nil; }
    if (!sig || sig.numberOfArguments != 2) return nil;
    const char *ret = [sig methodReturnType];
    if (!ret) return nil;
    @try {
        switch (ret[0]) {
            case '@': {
                id v = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
                if (!v || v == [NSNull null]) return nil;
                return [NSString stringWithFormat:@"%@", v];
            }
            case 'q': case 'l': {
                long long v = ((long long (*)(id, SEL))objc_msgSend)(obj, sel);
                return v ? [NSString stringWithFormat:@"%lld", v] : nil;
            }
            case 'Q': case 'L': {
                unsigned long long v =
                    ((unsigned long long (*)(id, SEL))objc_msgSend)(obj, sel);
                return v ? [NSString stringWithFormat:@"%llu", v] : nil;
            }
            case 'i': {
                int v = ((int (*)(id, SEL))objc_msgSend)(obj, sel);
                return v ? [NSString stringWithFormat:@"%d", v] : nil;
            }
            case 'I': {
                unsigned int v = ((unsigned int (*)(id, SEL))objc_msgSend)(obj, sel);
                return v ? [NSString stringWithFormat:@"%u", v] : nil;
            }
            default: return nil;
        }
    } @catch (NSException *e) {
        return nil;
    }
}

static BOOL max_dimLooksLikeMessage(id obj) {
    if (!obj) return NO;
    if ([obj isKindOfClass:[UIView class]]) return NO;
    if ([obj isKindOfClass:[NSString class]]) return NO;
    if ([obj isKindOfClass:[NSNumber class]]) return NO;
    if ([obj isKindOfClass:[NSArray class]]) return NO;
    if ([obj isKindOfClass:[NSDictionary class]]) return NO;
    if ([obj respondsToSelector:sel_registerName("primaryKey")]) return YES;
    if ([obj respondsToSelector:sel_registerName("messageId")]) return YES;
    if ([obj respondsToSelector:sel_registerName("serverId")]) return YES;
    return NO;
}

static NSArray<NSString *> *max_dimKeysForMessage(id message) {
    if (!message) return @[];
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSString *name in max_dimIdSelectorNames()) {
        NSString *v = max_dimStringValue(message, sel_registerName(name.UTF8String));
        if (v.length && ![keys containsObject:v]) [keys addObject:v];
    }
    // the message may wrap the real model (view model -> message)
    for (NSString *path in @[ @"message", @"model", @"messageModel" ]) {
        id inner = nil;
        @try { inner = [message valueForKey:path]; }
        @catch (NSException *e) { continue; }
        if (!max_dimLooksLikeMessage(inner)) continue;
        for (NSString *name in max_dimIdSelectorNames()) {
            NSString *v = max_dimStringValue(inner, sel_registerName(name.UTF8String));
            if (v.length && ![keys containsObject:v]) [keys addObject:v];
        }
    }
    return keys;
}

// ============================================================================
#pragma mark - Finding the message behind a cell
//
// KVC paths first (cheap, ARC-correct, weak-safe); if the cell exposes none
// of them, a bounded scan over @objc object properties of the cell and its
// direct children. Views, strings, numbers and collections are skipped so we
// never walk into the view hierarchy.
// ============================================================================

static id max_dimScanForMessage(id obj, int depth) {
    if (!obj || depth > 2) return nil;
    if (max_dimLooksLikeMessage(obj)) return obj;

    Class cls = object_getClass(obj);
    while (cls && cls != [NSObject class] && cls != [UIView class] &&
           cls != [UICollectionViewCell class] && cls != [UICollectionReusableView class]) {
        unsigned int count = 0;
        objc_property_t *props = class_copyPropertyList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *attrs = property_getAttributes(props[i]);
            if (!attrs || attrs[0] != 'T' || attrs[1] != '@') continue;  // objects only
            const char *cname = property_getName(props[i]);
            if (!cname) continue;
            NSString *name = [NSString stringWithUTF8String:cname];
            if (name.length == 0) continue;
            id value = nil;
            @try { value = [obj valueForKey:name]; }
            @catch (NSException *e) { continue; }
            if (!value) continue;
            if ([value isKindOfClass:[UIView class]] ||
                [value isKindOfClass:[CALayer class]] ||
                [value isKindOfClass:[UIViewController class]] ||
                [value isKindOfClass:[NSString class]] ||
                [value isKindOfClass:[NSNumber class]] ||
                [value isKindOfClass:[NSArray class]] ||
                [value isKindOfClass:[NSDictionary class]]) continue;
            id found = max_dimScanForMessage(value, depth + 1);
            if (found) { free(props); return found; }
        }
        free(props);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static id max_dimMessageForCell(UIView *cell) {
    static NSArray *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths = @[ @"message", @"viewModel.message", @"viewModel.model",
                   @"model.message", @"item.message", @"messageViewModel.message",
                   @"cellModel.message", @"viewModel", @"model", @"item",
                   @"messageViewModel", @"cellModel" ];
    });
    for (NSString *path in paths) {
        id value = nil;
        @try { value = [cell valueForKeyPath:path]; }
        @catch (NSException *e) { continue; }
        if (max_dimLooksLikeMessage(value)) return value;
        id inner = max_dimScanForMessage(value, 1);
        if (inner) return inner;
    }
    return max_dimScanForMessage(cell, 0);
}

// ============================================================================
#pragma mark - Applying the dim
// ============================================================================

static BOOL g_dimLoggedMatch = NO;

static void max_dimApplyToCell(UIView *cell) {
    if (!cell) return;
    UIView *target = cell;
    if ([cell isKindOfClass:[UICollectionViewCell class]])
        target = ((UICollectionViewCell *)cell).contentView ?: cell;

    NSSet<NSString *> *marked = max_dimMarkedSet();
    if (marked.count == 0) {                       // nothing marked: cheap path
        if (target.alpha < 0.999) target.alpha = 1.0;
        return;
    }

    id message = max_dimMessageForCell(cell);
    BOOL isMarked = NO;
    for (NSString *key in max_dimKeysForMessage(message)) {
        if ([marked containsObject:key]) { isMarked = YES; break; }
    }

    if (isMarked && !g_dimLoggedMatch) {
        g_dimLoggedMatch = YES;
        dimlog(@"first match: cell %@ / message %@",
               NSStringFromClass([cell class]), NSStringFromClass([message class]));
    }

    CGFloat wanted = isMarked ? kMAXDimAlpha : 1.0;
    if (fabs(target.alpha - wanted) > 0.001) target.alpha = wanted;
}

// ============================================================================
#pragma mark - layoutSubviews override on the message cell classes
// ============================================================================

#define MAXDIM_MAX_CLASSES 24

typedef struct {
    __unsafe_unretained Class cls;
    IMP orig;                      // NULL when we added a fresh override
} MAXDimEntry;

static MAXDimEntry g_dimEntries[MAXDIM_MAX_CLASSES];
static int g_nDimEntries = 0;

static MAXDimEntry *max_dimEntryForInstance(id instance) {
    Class cls = object_getClass(instance);
    while (cls) {
        for (int i = 0; i < g_nDimEntries; i++)
            if (g_dimEntries[i].cls == cls) return &g_dimEntries[i];
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void hook_dimLayoutSubviews(id self, SEL _cmd) {
    MAXDimEntry *entry = max_dimEntryForInstance(self);
    if (entry && entry->orig) {
        ((void (*)(id, SEL))entry->orig)(self, _cmd);
    } else {
        struct objc_super sup;
        sup.receiver = self;
        sup.super_class = class_getSuperclass(entry ? entry->cls : object_getClass(self));
        ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
    }
    @try { max_dimApplyToCell((UIView *)self); }
    @catch (NSException *e) { /* never break layout because of the dim */ }
}

static BOOL max_dimClassImplements(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { found = YES; break; }
    }
    free(methods);
    return found;
}

static void max_dimInstallOnClass(Class cls) {
    if (!cls || g_nDimEntries >= MAXDIM_MAX_CLASSES) return;
    for (int i = 0; i < g_nDimEntries; i++)
        if (g_dimEntries[i].cls == cls) return;

    SEL sel = @selector(layoutSubviews);
    MAXDimEntry entry;
    entry.cls = cls;
    entry.orig = NULL;

    if (max_dimClassImplements(cls, sel)) {
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;
        entry.orig = method_getImplementation(m);
        g_dimEntries[g_nDimEntries++] = entry;
        method_setImplementation(m, (IMP)hook_dimLayoutSubviews);
        dimlog(@"hook installed (swizzled own layoutSubviews) on %@",
               NSStringFromClass(cls));
    } else {
        // The class inherits layoutSubviews: add a REAL override here instead
        // of mutating the superclass method for every cell in the app.
        g_dimEntries[g_nDimEntries++] = entry;
        if (class_addMethod(cls, sel, (IMP)hook_dimLayoutSubviews, "v@:")) {
            dimlog(@"hook installed (added override) on %@", NSStringFromClass(cls));
        } else {
            g_nDimEntries--;
            dimlog(@"hook FAILED on %@", NSStringFromClass(cls));
        }
    }
}

// ============================================================================
#pragma mark - Immediate refresh of visible cells
// ============================================================================

static void max_dimRefreshInView(UIView *view, int depth) {
    if (!view || depth > 12) return;
    if ([view isKindOfClass:[UICollectionView class]]) {
        for (UICollectionViewCell *cell in ((UICollectionView *)view).visibleCells) {
            if (!max_dimEntryForInstance(cell)) continue;
            @try { max_dimApplyToCell(cell); }
            @catch (NSException *e) { }
        }
        return;
    }
    for (UIView *sub in view.subviews) max_dimRefreshInView(sub, depth + 1);
}

static void max_dimRefreshAll(void) {
    max_dimInvalidateMarked();
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            max_dimRefreshInView(window, 0);
    }
}

@interface MAXDimObserver : NSObject
@end

@implementation MAXDimObserver

- (void)defaultsChanged:(NSNotification *)note {
    static NSTimeInterval last = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - last < 0.2) return;              // defaults fire often; debounce
    last = now;
    dispatch_async(dispatch_get_main_queue(), ^{ max_dimRefreshAll(); });
}

@end

static MAXDimObserver *g_dimObserver = nil;

// ============================================================================
#pragma mark - Constructor
// ============================================================================

__attribute__((constructor))
static void maxmods_dim_init(void) {
    // 1) the known chat message cell, plus any other MessageCell-like
    //    collection cell (the class that actually renders may differ).
    max_dimInstallOnClass(objc_getClass("_TtC13ChatHistoryUI11MessageCell"));

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned int i = 0; i < classCount && g_nDimEntries < MAXDIM_MAX_CLASSES; i++) {
        const char *cname = class_getName(classes[i]);
        if (!cname || !strstr(cname, "MessageCell")) continue;
        Class super = classes[i];
        BOOL isCollectionCell = NO;
        while (super) {
            if (super == [UICollectionViewCell class]) { isCollectionCell = YES; break; }
            super = class_getSuperclass(super);
        }
        if (!isCollectionCell) continue;
        max_dimInstallOnClass(classes[i]);
    }
    free(classes);

    if (g_nDimEntries == 0)
        dimlog(@"WARNING: no message cell class found — dimming inactive");

    // 2) refresh visible cells as soon as the marked set changes
    g_dimObserver = [MAXDimObserver new];
    [[NSNotificationCenter defaultCenter] addObserver:g_dimObserver
                                             selector:@selector(defaultsChanged:)
                                                 name:NSUserDefaultsDidChangeNotification
                                               object:nil];

    dimlog(@"v6.6 dim module ready (%d cell class(es), alpha %.2f)",
           g_nDimEntries, kMAXDimAlpha);
}

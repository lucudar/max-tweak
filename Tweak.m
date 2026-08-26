/**
 * MAXMods v2.4 — EMPTY test (just logs, no hooks)
 * If this still crashes, the problem is the binary/injection itself.
 */

#import <Foundation/Foundation.h>

__attribute__((constructor))
static void maxmods_init(void) {
    NSLog(@"[MAXMods] v2.4 EMPTY dylib loaded — no hooks active");
}

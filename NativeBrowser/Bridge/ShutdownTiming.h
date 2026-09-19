//
//  ShutdownTiming.h
//  NativeBrowser
//
//  Shared monotonic clock for shutdown-latency measurements.
//
//  Why this exists: the termination sequence spans three languages (AppKit /
//  Swift, the Objective-C++ bridge, and CEF's C++ callbacks), and a latency
//  measurement is only meaningful on one clock. Swift and the bridge both
//  timestamp against this epoch, which is a monotonic clock - never the wall
//  clock, which can jump.
//
//  Recording is off unless it is explicitly enabled (pass --log-shutdown-timing),
//  so a normal run pays nothing.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Enables shutdown phase recording and resets the shared epoch.
void NBShutdownTimingEnable(void);

/// Whether recording is enabled (1 = yes). Declared as a plain integral type so
/// the Objective-C BOOL macro cannot change the signature between the Swift
/// importer and the Objective-C++ definition.
signed char NBShutdownTimingIsEnabled(void);

/// Milliseconds since the shared epoch, or 0 when timing is disabled.
double NBShutdownTimingNow(void);

/// Records a phase and prints "shutdown-phase: <name> +<ms since epoch>".
/// No-op when timing is disabled. Main thread only.
void NBShutdownTimingMark(NSString *phase);

/// Prints "shutdown-report: <name> +<ms>" for an explicit timestamp. Used for
/// begin/end pairs, where the value must be captured at the call site so that a
/// call which never returns is still visible. No-op when timing is disabled.
void NBShutdownTimingReport(NSString *name, double milliseconds);

/// Main-thread liveness detector.
///
/// Starts a repeating main-thread timer. While it fires, the run loop is alive;
/// the moment the gap between prints grows, the main thread is blocked. This is
/// what distinguishes "the run loop is stuck inside a CEF call" from "the run
/// loop is fine but something never arrives". No-op when timing is disabled.
void NBShutdownTimingStartLivenessWatchdog(void);
void NBShutdownTimingStopLivenessWatchdog(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

//
//  ShutdownTiming.mm
//  NativeBrowser
//
//  See ShutdownTiming.h.
//

#import "ShutdownTiming.h"

#include <chrono>

namespace {

/// Monotonic clock. steady_clock never jumps backwards, unlike the wall clock.
using Clock = std::chrono::steady_clock;

Clock::time_point gEpoch;
BOOL gEnabled = NO;

}  // namespace

// Defined with explicit C linkage (and BOOL spelled out) so the symbols match
// the declarations Swift imports from the header.
extern "C" {

void NBShutdownTimingEnable(void) {
  gEpoch = Clock::now();
  gEnabled = YES;
}

signed char NBShutdownTimingIsEnabled(void) {
  return gEnabled ? 1 : 0;
}

double NBShutdownTimingNow(void) {
  if (!gEnabled) {
    return 0.0;
  }
  const auto delta = Clock::now() - gEpoch;
  return std::chrono::duration<double, std::milli>(delta).count();
}

void NBShutdownTimingMark(NSString *phase) {
  if (!gEnabled) {
    return;
  }
  const double ms = NBShutdownTimingNow();
  fprintf(stderr, "shutdown-phase: %s +%.1fms\n", phase.UTF8String, ms);
}

void NBShutdownTimingReport(NSString *name, double milliseconds) {
  if (!gEnabled) {
    return;
  }
  fprintf(stderr, "shutdown-report: %s +%.1fms\n", name.UTF8String, milliseconds);
}

void NBShutdownTimingStartLivenessWatchdog(void) {
  if (!gEnabled) {
    return;
  }
  static NSTimer *watchdog = nil;
  if (watchdog != nil) {
    return;
  }
  __block double previous = NBShutdownTimingNow();
  fprintf(stderr, "shutdown-report: watchdog:start +%.1fms\n", previous);
  watchdog = [NSTimer scheduledTimerWithTimeInterval:1.0
                                            repeats:YES
                                              block:^(NSTimer *timer) {
      const double now = NBShutdownTimingNow();
      fprintf(stderr,
              "shutdown-report: liveness +%.1fms (gap %.0fms)\n",
              now, now - previous);
      previous = now;
  }];
  // .common so it also fires while AppKit is in a modal or tracking run loop.
  [NSRunLoop.mainRunLoop addTimer:watchdog forMode:NSRunLoopCommonModes];
}

void NBShutdownTimingStopLivenessWatchdog(void) {
  // Nothing to do: the watchdog is only for diagnosis while termination is in
  // flight, and the process is about to exit. Kept for symmetry.
}

}  // extern "C"

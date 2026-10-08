#include "chrome/browser/ui/cio/CioHostedMessagePump.h"

#include <limits>

namespace cio {
std::unique_ptr<base::MessagePump> CreateHostedMessagePump() {
  // The factory is process-wide: Chromium also creates UI pumps on worker
  // threads. Only the AppKit main thread may register the native-menu pump.
  if (NSThread.isMainThread)
    return std::make_unique<HostedMessagePump>();
  return base::message_pump_apple::Create();
}

void HostedMessagePump::DoRun(Delegate* delegate) {
  // Pump CF sources without invoking NSApp.run or consuming native
  // events inside Cio's timer. The CrApplication base retains the menu-mode
  // registration and autorelease protection used by DisplayPopupMenu.
  int result;
  constexpr CFTimeInterval maximum_wait =
      std::numeric_limits<CFTimeInterval>::max();
  do {
    if (ShouldCreateAutoreleasePool()) {
      @autoreleasepool {
        result = CFRunLoopRunInMode(kCFRunLoopDefaultMode,
                                   maximum_wait, true);
      }
    } else {
      result = CFRunLoopRunInMode(kCFRunLoopDefaultMode,
                                 maximum_wait, true);
    }
    // A deferred quit can be applied by an inner loop's exit observer. Return
    // after each source so that such a quit cannot strand the outer CF pass.
  } while (keep_running() && result != kCFRunLoopRunStopped &&
           result != kCFRunLoopRunFinished);
}

bool HostedMessagePump::DoQuit() {
  // Never stop NSApp, or stop a native menu/modal loop nested inside our pass.
  if (nesting_level() == run_nesting_level()) {
    CFRunLoopStop(run_loop());
    return true;
  }
  quit_pending_ = true;
  return false;
}

void HostedMessagePump::EnterExitRunLoop(CFRunLoopActivity activity) {
  if (activity == kCFRunLoopExit && nesting_level() == run_nesting_level() &&
      quit_pending_) {
    CFRunLoopStop(run_loop());
    quit_pending_ = false;
    OnDidQuit();
  }
}
}  // namespace cio

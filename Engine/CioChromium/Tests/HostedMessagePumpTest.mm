#import <AppKit/AppKit.h>

#include <thread>

#include "Engine/CioChromium/Native/CioHostedMessagePump.h"
#include "base/at_exit.h"
#include "base/check.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/mac/scoped_sending_event.h"
#include "base/task/single_thread_task_executor.h"
#include "base/task/single_thread_task_runner.h"

@interface CioPumpTestApplication : NSApplication <CrAppControlProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
@implementation CioPumpTestApplication
@synthesize handlingSendEvent = _handlingSendEvent;
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
@end

int main() {
  base::AtExitManager at_exit;
  @autoreleasepool {
    [CioPumpTestApplication sharedApplication];
    base::MessagePump::OverrideMessagePumpForUIFactory(&cio::CreateHostedMessagePump);
    auto hosted_pump = base::MessagePump::Create(base::MessagePumpType::UI);
    auto* pump = hosted_pump.get();
    base::SingleThreadTaskExecutor executor(std::move(hosted_pump));
    int menu_modes = 0;
    // DisplayPopupMenu uses both scopes before entering native menu tracking.
    // Re-entry DCHECKs the restored modal-safe mask on every iteration.
    for (int i = 0; i < 3; ++i) {
      base::mac::ScopedSendingEvent sending_event;
      base::ScopedPumpMessagesInPrivateModes private_modes;
      if (i == 0) menu_modes = private_modes.GetModeMaskForTest();
      CHECK_GT(menu_modes, 0);
      CHECK_EQ(menu_modes, private_modes.GetModeMaskForTest());
      CHECK(base::message_pump_apple::IsHandlingSendEvent());
      fprintf(stderr, "menu-pump-test: running task pass %d\n", i);
      bool ran = false;
      base::RunLoop loop;
      executor.task_runner()->PostTask(FROM_HERE, base::BindOnce(
          [](bool* ran, base::OnceClosure quit) {
            *ran = true;
            std::move(quit).Run();
          }, &ran, loop.QuitClosure()));
      loop.Run();
      CHECK(ran);
    }
    CHECK(!base::message_pump_apple::IsHandlingSendEvent());
    // Chromium's process-wide UI factory is also used by background threads.
    // Their pump must not try to replace the main thread's menu registration.
    std::thread worker([] {
      @autoreleasepool {
        base::SingleThreadTaskExecutor executor(base::MessagePumpType::UI);
        bool ran = false;
        executor.task_runner()->PostTask(FROM_HERE, base::BindOnce(
            [](bool* ran) { *ran = true; }, &ran));
        base::RunLoop().RunUntilIdle();
        CHECK(ran);
      }
    });
    worker.join();
    {
      base::ScopedPumpMessagesInPrivateModes private_modes;
      CHECK_EQ(menu_modes, private_modes.GetModeMaskForTest());
    }
    fprintf(stderr, "menu-pump-test: running nested native quit\n");
    // A quit requested inside a native nested loop must wait for that loop to
    // finish, rather than cancelling menu tracking or stopping NSApplication.
    bool native_finished = false;
    base::RunLoop outer;
    executor.task_runner()->PostTask(FROM_HERE, base::BindOnce(
        [](bool* finished, base::MessagePump* pump) {
          struct Context {
            raw_ptr<base::MessagePump> pump;
            bool quit_requested = false;
            bool finished = false;
          } context{pump};
          CFRunLoopTimerContext timer_context = {0, &context};
          auto timer = base::apple::ScopedCFTypeRef<CFRunLoopTimerRef>(
              CFRunLoopTimerCreate(nullptr, CFAbsoluteTimeGetCurrent(), 0.001, 0, 0,
                  [](CFRunLoopTimerRef, void* data) {
                    auto* context = static_cast<Context*>(data);
                    if (!context->quit_requested) {
                      context->pump->Quit();
                      context->quit_requested = true;
                      return;
                    }
                    context->finished = true;
                    CFRunLoopStop(CFRunLoopGetCurrent());
                  }, &timer_context));
          CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer.get(), kCFRunLoopDefaultMode);
          CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1, false);
          CFRunLoopTimerInvalidate(timer.get());
          CHECK(context.finished);
          *finished = context.finished;
        }, &native_finished, base::Unretained(pump)));
    outer.Run();
    CHECK(native_finished);
    base::RunLoop().RunUntilIdle();
    puts("PASS: menu scopes restore, main/worker tasks run and nested native quit completes");
  }
}

#import <AppKit/AppKit.h>
#include <thread>
#include "Engine/CioChromium/Native/CioHostedMessagePump.h"
#include "base/at_exit.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/mac/scoped_sending_event.h"
#include "base/task/single_thread_task_executor.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"

@interface CioRunLoopTestApplication : NSApplication <CrAppControlProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
@implementation CioRunLoopTestApplication
@synthesize handlingSendEvent = _handlingSendEvent;
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
@end

namespace {
base::AtExitManager* at_exit;
base::SingleThreadTaskExecutor* executor;
int completed = 0;
}
#pragma GCC visibility push(default)
extern "C" {
void CioRunLoopTestStart() {
  at_exit = new base::AtExitManager();
  [CioRunLoopTestApplication sharedApplication];
  base::MessagePump::OverrideMessagePumpForUIFactory(&cio::CreateHostedMessagePump);
  executor = new base::SingleThreadTaskExecutor(base::MessagePumpType::UI);
}
void CioRunLoopTestPump() { base::RunLoop().RunUntilIdle(); }
int CioRunLoopTestCompleted() { return completed; }
void CioRunLoopTestPost(int delay_ms, bool worker) {
  auto runner = executor->task_runner();
  auto post = [runner, delay_ms] {
    runner->PostDelayedTask(FROM_HERE, base::BindOnce([] { ++completed; }),
                            base::Milliseconds(delay_ms));
  };
  if (worker) std::thread(post).join();
  else post();
}
void CioRunLoopTestStop() {
  delete executor;
  executor = nullptr;
  delete at_exit;
  at_exit = nullptr;
}
}
#pragma GCC visibility pop

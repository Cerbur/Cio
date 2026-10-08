#ifndef CIO_HOSTED_MESSAGE_PUMP_H_
#define CIO_HOSTED_MESSAGE_PUMP_H_

#include "base/message_loop/message_pump_apple.h"

namespace cio {
// Register Chromium's native-menu pump while leaving event dispatch to Cio's
// AppKit loop. Only explicit Chromium Run calls spin a CFRunLoop pass.
class HostedMessagePump final : public base::MessagePumpCrApplication {
 protected:
  void DoRun(Delegate* delegate) override;
  bool DoQuit() override;

 private:
  void EnterExitRunLoop(CFRunLoopActivity activity) override;
  bool quit_pending_ = false;
};

std::unique_ptr<base::MessagePump> CreateHostedMessagePump();
}  // namespace cio

#endif  // CIO_HOSTED_MESSAGE_PUMP_H_

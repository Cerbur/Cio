#import "ChromiumProcessHost.h"

@interface ChromiumProcessHost (CEFScheduling)
// The CEF process handler schedules external-loop work; this is not part of
// the application's engine-facing interface.
+ (void)scheduleMessagePumpWorkAfter:(double)delay;
@end

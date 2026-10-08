#pragma once

#include <memory>
#include "chrome/app/startup_timestamps.h"
#include "content/public/app/content_main.h"

class ChromeMainDelegate;
namespace cio {
std::unique_ptr<ChromeMainDelegate> CreateMainDelegate(const StartupTimestamps&);
int RunHostedContent(content::ContentMainParams,
                     std::unique_ptr<ChromeMainDelegate>);
bool IsHostedBrowser();
}

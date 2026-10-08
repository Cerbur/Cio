#include "chrome/browser/ui/cio/CioNativeRuntime.h"
#include "chrome/browser/ui/cio/CioWindowHooks.h"
#import "chrome/browser/ui/cio/CioNativeExports.h"

#include <algorithm>
#include <string_view>
#include "base/command_line.h"
#include "base/compiler_specific.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/run_loop.h"
#include "base/message_loop/message_pump.h"
#include "base/message_loop/message_pump_apple.h"
#include "chrome/app/chrome_main_delegate.h"
#include "chrome/browser/browser_process.h"
#include "components/keep_alive_registry/scoped_keep_alive.h"
#include "components/keep_alive_registry/keep_alive_types.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "components/prefs/pref_service.h"
#include "components/language/core/browser/pref_names.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "content/public/app/content_main_runner.h"
#include "content/public/browser/browser_main_runner.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/common/main_function_params.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "ui/native_theme/native_theme.h"

extern "C" int ChromeMain(int, const char **);

namespace {
class HostedMessagePump final : public base::MessagePumpCFRunLoop {
 protected:
  bool ShouldCreateAutoreleasePool() override {
    // Match CrApplication's lifetime protection during AppKit event tracking.
    return !base::message_pump_apple::IsHandlingSendEvent();
  }
};
struct Runtime {
  std::unique_ptr<ChromeMainDelegate> delegate;
  std::unique_ptr<content::ContentMainRunner> content;
  std::unique_ptr<content::BrowserMainRunner> browser;
  std::unique_ptr<ScopedKeepAlive> keep_alive;
  std::unique_ptr<ScopedProfileKeepAlive> profile_keep_alive;
  bool initialized = false;
};
Runtime& State() {
  static base::NoDestructor<Runtime> state;
  return *state;
}

class HostedMainDelegate final : public ChromeMainDelegate {
 public:
  explicit HostedMainDelegate(const StartupTimestamps& timestamps)
      : ChromeMainDelegate(timestamps) {}
 protected:
  std::variant<int, content::MainFunctionParams> RunProcess(
      const std::string& type, content::MainFunctionParams parameters) override {
    if (!type.empty())
      return ChromeMainDelegate::RunProcess(type, std::move(parameters));
    // RunContentProcess owns a stack autorelease pool. Cio owns the subsequent
    // AppKit loop, so BrowserMainLoop must not retain that pool's pointer.
    parameters.autorelease_pool = nullptr;
    State().browser = content::BrowserMainRunner::Create();
    const int result = State().browser->Initialize(std::move(parameters));
    State().initialized = result < 0;
    return result < 0 ? 0 : result;
  }
};

// RunContentProcess performs Chromium's normal allocator, signal, sandbox and
// content initialization. Its final Shutdown call is deferred until Cio has
// closed its pages and returned from its own AppKit run loop.
class HostedContentRunner final : public content::ContentMainRunner {
 public:
  int Initialize(content::ContentMainParams params) override {
    return State().content->Initialize(std::move(params));
  }
  void ReInitializeParams(content::ContentMainParams params) override {
    State().content->ReInitializeParams(std::move(params));
  }
  int Run() override { return State().content->Run(); }
  void Shutdown() override {}
};
}

namespace cio {
bool IsHostedBrowser() {
  auto* command = base::CommandLine::ForCurrentProcess();
  return command && command->HasSwitch("cio-embedded-browser") &&
         !command->HasSwitch("type");
}
std::unique_ptr<ChromeMainDelegate> CreateMainDelegate(
    const StartupTimestamps& timestamps) {
  return std::make_unique<HostedMainDelegate>(timestamps);
}
int RunHostedContent(content::ContentMainParams params,
                     std::unique_ptr<ChromeMainDelegate> delegate) {
  State().delegate = std::move(delegate);
  params.delegate = State().delegate.get();
  State().content = content::ContentMainRunner::Create();
  HostedContentRunner runner;
  return content::RunContentProcess(std::move(params), &runner);
}
}

int CioNativeStart(int argc, const char **argv) {
  if (State().initialized) return 0;
  bool hosted = false;
  for (int i = 0; i < argc; ++i)
    // The native entry point supplies exactly argc argument pointers.
    if (std::string_view(UNSAFE_BUFFERS(argv[i])) == "--cio-embedded-browser") hosted = true;
  if (hosted && !base::MessagePump::IsMessagePumpForUIFactoryOveridden()) {
    // AppKit owns event dispatch. Chromium polls its CF sources without
    // starting another NSApplication event loop inside a Cio timer/gesture.
    base::MessagePump::OverrideMessagePumpForUIFactory(+[]() -> std::unique_ptr<base::MessagePump> {
      return std::make_unique<HostedMessagePump>();
    });
  }
  int result = ChromeMain(argc, argv);
  if (State().initialized) {
    State().keep_alive = std::make_unique<ScopedKeepAlive>(
        KeepAliveOrigin::CHROME_APP_DELEGATE, KeepAliveRestartOption::DISABLED);
    auto* profile = ProfileManager::GetLastUsedProfile();
    State().profile_keep_alive = std::make_unique<ScopedProfileKeepAlive>(
        profile, ProfileKeepAliveOrigin::kAppWindow);
    auto* preferences = profile->GetPrefs();
    if (!preferences->GetBoolean("cio.language_defaults_initialized")) {
      std::vector<std::string> languages;
      for (NSString* identifier in NSLocale.preferredLanguages) {
        NSDictionary* parts = [NSLocale componentsFromLocaleIdentifier:identifier];
        NSString* language = parts[NSLocaleLanguageCode];
        NSString* country = parts[NSLocaleCountryCode];
        NSString* script = parts[NSLocaleScriptCode];
        NSString* value = [identifier stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
        if ([language isEqualToString:@"zh"]) {
          if ([country isEqualToString:@"HK"] || [country isEqualToString:@"MO"])
            value = [@"zh-" stringByAppendingString:country];
          else if ([script isEqualToString:@"Hant"] || [country isEqualToString:@"TW"])
            value = @"zh-TW";
          else value = @"zh-CN";
        }
        auto normalized = base::SysNSStringToUTF8(value);
        if (std::find(languages.begin(), languages.end(), normalized) == languages.end()) languages.push_back(normalized);
      }
      auto value = base::JoinString(languages, ",");
      if (!value.empty()) preferences->SetString(language::prefs::kSelectedLanguages, value);
      preferences->SetBoolean("cio.language_defaults_initialized", true);
    }
  }
  return result;
}
BOOL CioNativeIsInitialized() { return State().initialized; }
void CioNativeShutdown() {
  if (!State().content) return;
  State().initialized = false;
  cio::ShutdownDownloads();
  if (State().browser) {
    State().browser->Shutdown();
    State().browser.reset();
  }
  // Releasing the final keep-alive while BrowserProcess still observes the
  // registry invokes Chrome's own quit closure (which Cio does not run).
  // First shut down BrowserProcess normally, then release the host lifetime.
  State().keep_alive.reset();
  State().profile_keep_alive.reset();
  State().content->Shutdown();
  State().content.reset();
  State().delegate.reset();
}
void CioNativePump() {
  if (State().initialized) {
    base::RunLoop().RunUntilIdle();
    cio::RefreshDevTools();
  }
}
void CioNativeFlushCookies(void (^completion)(BOOL)) {
  auto* profile = State().initialized
      ? ProfileManager::GetLastUsedProfileIfLoaded() : nullptr;
  if (!profile) { completion(NO); return; }
  void (^callback)(BOOL) = [completion copy];
  profile->GetDefaultStoragePartition()->GetCookieManagerForBrowserProcess()
      ->FlushCookieStore(base::BindOnce([](void (^done)(BOOL)) { done(YES); }, callback));
}
void CioNativeSetDarkAppearance(BOOL dark) {
  auto* theme = ui::NativeTheme::GetInstanceForNativeUi();
  theme->set_preferred_color_scheme(dark ? ui::NativeTheme::PreferredColorScheme::kDark
                                        : ui::NativeTheme::PreferredColorScheme::kLight);
  theme->NotifyOnNativeThemeUpdated();
}

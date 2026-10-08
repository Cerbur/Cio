//
//  ChromiumProcessHost.mm
//  Cio
//
//  Objective-C++ implementation of the CEF lifecycle boundary.
//  Provenance: Cio's former Cio/Bridge/CEFProcessHost.mm, renamed and relocated.
//  Third-party dependencies and reference scope: THIRD_PARTY_NOTICES.md.
//
//  On macOS the CEF framework must be loaded at runtime from the app bundle
//  (CefScopedLibraryLoader) instead of being linked directly; that is a
//  requirement of the Chromium sandbox implementation and it is how the CEF
//  binary distribution expects client applications to start up.
//

#import "ChromiumProcessHost+CEF.h"
#import <AppKit/AppKit.h>

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_request_context.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

/// Chrome WebUI needs a Chrome-style top-level browser on macOS. A parent
/// NSView forces Alloy, which blocks chrome://settings before it can load.
/// Own every Chrome UI browser here, including tabs/windows Chrome creates,
/// and wait for typed OnBeforeClose callbacks before shutting down CEF.
class ChromeSettingsClient final : public CefClient,
                                   public CefLifeSpanHandler {
 public:
  ChromeSettingsClient() = default;
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  bool Open(const std::string& url) {
    if (closing_) return false;
    pending_url_ = url;
    if (!browsers_.empty()) {
      auto browser = browsers_.front();
      browser->GetMainFrame()->LoadURL(url);
      Show(browser);
      return true;
    }
    if (pending_) return true;
    CefWindowInfo window;
    window.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    window.bounds = CefRect(120, 120, 1000, 760);
    CefBrowserSettings settings;
    pending_ = CefBrowserHost::CreateBrowser(
        window, this, url, settings, nullptr, CefRequestContext::GetGlobalContext());
    return pending_;
  }

  bool HasLiveBrowsers() const { return pending_ || !browsers_.empty(); }

  void CloseAll(void (^completion)(void)) {
    closing_ = true;
    completion_ = [completion copy];
    // CloseBrowser may initiate callbacks; don't iterate a mutable registry.
    auto browsers = browsers_;
    for (auto browser : browsers) browser->GetHost()->CloseBrowser(true);
    CompleteIfClosed();
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browsers_.push_back(browser);
    browser->GetHost()->SetAccessibilityState(STATE_ENABLED);
    if (pending_) {
      pending_ = false;
      browser->GetMainFrame()->LoadURL(pending_url_);
    }
    if (closing_) browser->GetHost()->CloseBrowser(true);
    else Show(browser);
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    std::erase_if(browsers_, [&](const auto& item) { return item->IsSame(browser); });
    CompleteIfClosed();
  }

 private:
  static void Show(CefRefPtr<CefBrowser> browser) {
    NSView *view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    [view.window makeKeyAndOrderFront:nil];
    browser->GetHost()->SetFocus(true);
  }

  void CompleteIfClosed() {
    if (!HasLiveBrowsers() && completion_) {
      void (^completion)(void) = completion_;
      completion_ = nil;
      completion();
    }
  }

  std::vector<CefRefPtr<CefBrowser>> browsers_;
  std::string pending_url_;
  bool pending_ = false;
  bool closing_ = false;
  void (^completion_)(void) = nil;
  IMPLEMENT_REFCOUNTING(ChromeSettingsClient);
  DISALLOW_COPY_AND_ASSIGN(ChromeSettingsClient);
};

CefRefPtr<ChromeSettingsClient> gChromeSettingsClient;

CefRefPtr<ChromeSettingsClient> GetChromeSettingsClient() {
  if (!gChromeSettingsClient) gChromeSettingsClient = new ChromeSettingsClient();
  return gChromeSettingsClient;
}

constexpr char kLanguageDefaultsInitialized[] = "cio.language_defaults_initialized";

/// Apple uses script-qualified Chinese tags; Chrome's language settings use
/// zh-CN/zh-TW. Preserve the system's order and remove duplicate tags.
NSString *SystemPreferredLanguages() {
  NSMutableOrderedSet<NSString *> *languages = [NSMutableOrderedSet orderedSet];
  for (NSString *identifier in NSLocale.preferredLanguages) {
    NSDictionary *components = [NSLocale componentsFromLocaleIdentifier:identifier];
    NSString *language = components[NSLocaleLanguageCode];
    if (language.length == 0) continue;
    NSString *region = components[NSLocaleCountryCode];
    NSString *script = components[NSLocaleScriptCode];
    NSString *tag = [identifier stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    if ([language isEqualToString:@"zh"]) {
      if ([region isEqualToString:@"HK"] || [region isEqualToString:@"MO"]) {
        tag = @"zh-HK";
      } else {
        tag = ([script isEqualToString:@"Hant"] || [region isEqualToString:@"TW"])
            ? @"zh-TW" : @"zh-CN";
      }
    }
    [languages addObject:tag];
  }
  return languages.count ? [languages.array componentsJoinedByString:@","] : @"en-US,en";
}

/// The completion is delivered on CEF's UI thread. Swift schedules the next
/// shutdown step after this callback returns, keeping CefShutdown off-stack.
class CookieFlushCompletion final : public CefCompletionCallback {
 public:
  explicit CookieFlushCompletion(void (^completion)(BOOL))
      : completion_([completion copy]) {}
  void OnComplete() override { completion_(YES); }

 private:
  void (^completion_)(BOOL);
  IMPLEMENT_REFCOUNTING(CookieFlushCompletion);
  DISALLOW_COPY_AND_ASSIGN(CookieFlushCompletion);
};

/// Minimal CefApp implementation.
///
/// Milestone 0 only needs a valid CefApp to hand to CefInitialize(); browser
/// process handlers (context initialization, browser creation) arrive with the
/// first Chromium view in Milestone 1.
class CioApp final : public CefApp,
                              public CefBrowserProcessHandler {
 public:
  CioApp() = default;

  // CefApp
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  CefRefPtr<CefClient> GetDefaultClient() override {
    return GetChromeSettingsClient();
  }

  void OnBeforeCommandLineProcessing(
      const CefString &process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (process_type.empty()) {
#if defined(DEBUG)
      command_line->AppendSwitchWithValue("remote-debugging-address", "127.0.0.1");
      // Chromium's updater clones the app and hard-links the executable on a
      // background task that shutdown must await. Rebuilt ad-hoc Debug bundles
      // can stall that link(). Like Chrome for Testing, this app has no Chrome
      // auto-update flow. Preserve other feature switches and disable only the
      // updater's clone in Debug; normal macOS code signing remains in effect.
      std::string disabled = command_line->GetSwitchValue("disable-features").ToString();
      if (!disabled.empty()) disabled += ",";
      disabled += "MacAppCodeSignClone";
      command_line->AppendSwitchWithValue("disable-features", disabled);
#else
      // Switches override CefSettings; network debugging stays Debug-only.
      command_line->RemoveSwitch("remote-debugging-port");
      command_line->RemoveSwitch("remote-debugging-pipe");
#endif
    }
  }

  // CefBrowserProcessHandler
  void OnRegisterCustomPreferences(
      cef_preferences_type_t type,
      CefRawPtr<CefPreferenceRegistrar> registrar) override {
    if (type == CEF_PREFERENCES_TYPE_REQUEST_CONTEXT) {
      CefRefPtr<CefValue> value = CefValue::Create();
      value->SetBool(false);
      registrar->AddPreference(kLanguageDefaultsInitialized, value);
    }
  }

  void OnContextInitialized() override {
    CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext();
    CefRefPtr<CefValue> initialized = context->GetPreference(kLanguageDefaultsInitialized);
    if (!initialized || initialized->GetBool()) return;

    // Seed once in the Chrome profile (including profiles from older Cio
    // versions). Leave CefSettings.accept_language_list empty: CEF otherwise
    // overrides chrome://settings/languages on every request and restart.
    CefRefPtr<CefValue> languages = CefValue::Create();
    languages->SetString(SystemPreferredLanguages().UTF8String);
    CefString error;
    if (!context->SetPreference("intl.selected_languages", languages, error) ||
        !context->SetPreference("intl.accept_languages", languages, error)) {
      fprintf(stderr, "[cef] unable to initialize system language preferences\n");
      return;
    }
    initialized->SetBool(true);
    if (!context->SetPreference(kLanguageDefaultsInitialized, initialized, error)) {
      fprintf(stderr, "[cef] unable to persist language initialization\n");
    }
  }

  ///
  /// The external message pump contract: CEF asks the client to run
  /// CefDoMessageLoopWork() now (delay_ms <= 0) or after |delay_ms|. Ignoring
  /// this leaves delayed UI-thread work - including browser destruction -
  /// unprocessed, so the request is turned into a scheduled pump on the main
  /// run loop.
  void OnScheduleMessagePumpWork(int64_t delay_ms) override;

 private:
  IMPLEMENT_REFCOUNTING(CioApp);
  DISALLOW_COPY_AND_ASSIGN(CioApp);
};

/// The library loader must stay alive for as long as CEF is in use; it is
/// intentionally allocated once and released by process termination.
CefScopedLibraryLoader *gLibraryLoader = nullptr;

/// Backing storage for the argv vector handed to CefMainArgs. CEF keeps a
/// reference to these pointers for the lifetime of the process.
std::vector<std::string> gArguments;
std::vector<char *> gArgumentPointers;
bool gMockKeychainWasExplicit = false;
bool gMockKeychainWasImplicit = false;

/// Chromium switch that keeps the browser process away from the login
/// keychain.
///
/// Chromium stores the key it uses for cookie and password encryption in a
/// "Chromium Safe Storage" item in the login keychain. Development builds here
/// are ad-hoc signed (CODE_SIGN_IDENTITY "-"), so every rebuild produces a
/// binary with a different code signature; macOS then treats the lookup as a
/// request from a new application and shows a keychain authorization dialog.
/// That dialog is modal to the *process*: it blocks CEF's main thread, so the
/// application cannot create its window or pump its message loop until someone
/// answers it, which silently hangs both manual runs and the milestone
/// verification scripts.
///
/// With this switch Chromium uses an in-memory key instead, so no keychain item
/// is read or written and the dialog never appears. It is a Debug-only default;
/// Release never adds it implicitly. Release verification passes the switch
/// explicitly because this milestone does not claim a signed/notarized product
/// identity. Revisit before enabling saved passwords or account sync.
constexpr char kMockKeychainSwitch[] = "use-mock-keychain";

bool HasCommandLineSwitch(const std::vector<std::string> &arguments,
                          const char *switch_name) {
  const std::string prefix = std::string("--") + switch_name;
  for (const std::string &argument : arguments) {
    if (argument == prefix || argument.rfind(prefix + "=", 0) == 0) {
      return true;
    }
  }
  return false;
}

void BuildMainArgs() {
  if (!gArgumentPointers.empty()) {
    return;
  }
  NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
  gArguments.reserve(arguments.count + 1);
  for (NSString *argument in arguments) {
    const char *utf8 = argument.UTF8String;
    gArguments.emplace_back(utf8 != nullptr ? utf8 : "");
  }
  gMockKeychainWasExplicit = HasCommandLineSwitch(gArguments, kMockKeychainSwitch);
#if defined(DEBUG)
  // Development builds are ad-hoc signed and must avoid a keychain prompt. A
  // caller-provided switch remains supported, while Release has no implicit
  // mock-keychain behavior.
  if (!gMockKeychainWasExplicit) {
    gArguments.emplace_back(std::string("--") + kMockKeychainSwitch);
    gMockKeychainWasImplicit = true;
  }
#endif
  gArgumentPointers.reserve(gArguments.size());
  for (std::string &argument : gArguments) {
    gArgumentPointers.push_back(argument.data());
  }
}

CefMainArgs CreateMainArgs() {
  BuildMainArgs();
  return CefMainArgs(static_cast<int>(gArgumentPointers.size()),
                     gArgumentPointers.data());
}

/// Loads "Chromium Embedded Framework.framework" from
/// <Cio.app>/Contents/Frameworks. Must happen before the first CEF
/// call in this process.
BOOL EnsureFrameworkLoaded(NSError **error) {
  if (gLibraryLoader != nullptr) {
    return YES;
  }
  auto *loader = new CefScopedLibraryLoader();
  if (!loader->LoadInMain()) {
    delete loader;
    fprintf(stderr, "[cef] failed to load the Chromium Embedded Framework\n");
    if (error != nullptr) {
      *error = [NSError
          errorWithDomain:@"Cio.CEF"
                     code:3
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"The Chromium Embedded Framework could not be loaded."
                 }];
    }
    return NO;
  }
  gLibraryLoader = loader;
  return YES;
}

/// Directory that holds CEF's cache and log files. Overridable so that tests
/// and sandboxed development runs can keep everything inside the workspace.
NSString *RuntimeDataDirectory() {
  NSString *override =
      NSProcessInfo.processInfo.environment[@"CIO_DATA_DIR"];
  if (override.length > 0) {
    return override;
  }
  NSArray<NSString *> *paths =
      NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                          NSUserDomainMask, YES);
  NSString *base = paths.firstObject ?: NSHomeDirectory();
  return [base stringByAppendingPathComponent:@"Cio"];
}

BOOL EnsureDirectory(NSString *path, NSError **error) {
  return [NSFileManager.defaultManager createDirectoryAtPath:path
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:error];
}

/// Lifecycle state of the CEF runtime inside this process.
enum class RuntimeState {
  kNotInitialized,
  kInitialized,
  kFailed,
};

RuntimeState gState = RuntimeState::kNotInitialized;
NSString *gVersionString = nil;


}  // namespace

void CioApp::OnScheduleMessagePumpWork(int64_t delay_ms) {
  if (delay_ms <= 0) {
    // Work is pending right now; a zero-delay hop keeps the ordering correct
    // without spinning the run loop.
    [ChromiumProcessHost scheduleMessagePumpWorkAfter:0];
    return;
  }
  [ChromiumProcessHost scheduleMessagePumpWorkAfter:delay_ms / 1000.0];
}

@implementation ChromiumProcessHost

+ (NSString *)backendIdentifier { return @"cef-alloy"; }

+ (void)setDarkAppearance:(BOOL)dark {
  NSAssert(NSThread.isMainThread,
           @"Chromium color scheme must be set on the CEF UI thread.");
  if (gState != RuntimeState::kInitialized) {
    return;
  }
  CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext();
  if (!context) {
    return;
  }
  const cef_color_variant_t mode =
      dark ? CEF_COLOR_VARIANT_DARK : CEF_COLOR_VARIANT_LIGHT;
  if (context->GetChromeColorSchemeMode() != mode) {
    context->SetChromeColorScheme(mode, 0);
  }
}

+ (int)executeSubprocess {
  NSError *error = nil;
  if (!EnsureFrameworkLoaded(&error)) {
    return 1;
  }
  const CefMainArgs main_args = CreateMainArgs();
  fprintf(stderr, "[cef] mock-keychain: implicit=%s explicit=%s\n",
          gMockKeychainWasImplicit ? "yes" : "no",
          gMockKeychainWasExplicit ? "yes" : "no");
  // Returns -1 for the main browser process and the exit code for any
  // sub-process. Sub-processes normally run from the dedicated helper
  // executable (see Cio/Helper), this is a safety net.
  return CefExecuteProcess(main_args, nullptr, nullptr);
}

+ (BOOL)startWithError:(NSError **)error {
  if (gState == RuntimeState::kInitialized) {
    return YES;
  }
  if (gState == RuntimeState::kFailed) {
    if (error != nullptr) {
      *error = [NSError errorWithDomain:@"Cio.CEF"
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"CEF initialization previously failed."
                               }];
    }
    return NO;
  }

  NSAssert(NSThread.isMainThread,
           @"CefInitialize() must be called on the main thread.");

  if (!EnsureFrameworkLoaded(error)) {
    gState = RuntimeState::kFailed;
    return NO;
  }

  NSString *dataDirectory = RuntimeDataDirectory();
  NSString *cachePath = [dataDirectory stringByAppendingPathComponent:@"CEF"];
  NSString *logDirectory = [dataDirectory stringByAppendingPathComponent:@"Logs"];
  NSError *directoryError = nil;
  if (!EnsureDirectory(cachePath, &directoryError) ||
      !EnsureDirectory(logDirectory, &directoryError)) {
    fprintf(stderr, "[cef] unable to prepare private data directories\n");
    gState = RuntimeState::kFailed;
    if (error != nullptr) *error = directoryError;
    return NO;
  }

  const CefMainArgs main_args = CreateMainArgs();

  CefSettings settings;
  // All CEF callbacks are delivered through the application's own run loop
  // (NSApplication), so the message loop is pumped explicitly. See
  // ApplicationRuntime.startMessagePump().
  // The app owns the NSApplication run loop (SwiftUI), so CEF must not run the
  // loop itself; CefDoMessageLoopWork() is driven from the main run loop and
  // from CefBrowserProcessHandler::OnScheduleMessagePumpWork().
  settings.external_message_pump = true;
  settings.multi_threaded_message_loop = false;
  // The helper applications are not built with the CEF macOS sandbox
  // (CEF_USE_SANDBOX is undefined, matching CEF's -DUSE_SANDBOX=OFF builds), so
  // the Chromium sandbox has to be disabled here as well: a sandboxed child
  // expects a bootstrap namespace that only CefScopedSandboxContext prepares,
  // and without it the helper cannot reach the browser process over Mach IPC.
  // Turning the sandbox back on requires Developer ID signing for the app and
  // its helpers (ARCHITECTURE.md sections 33 and 34).
#if defined(CEF_USE_SANDBOX)
  settings.no_sandbox = false;
#else
  settings.no_sandbox = true;
#endif
  settings.log_severity = LOGSEVERITY_INFO;
  // Chromium owns the cookie database, expiry, security attributes and
  // encryption. Retain session cookies along with Cio's restored tabs.
  settings.persist_session_cookies = true;
  settings.remote_debugging_port = 0;
#if defined(DEBUG)
  // Network debugging is opt-in. The in-process inspector needs no listener.
  NSString *debugPort = NSProcessInfo.processInfo.environment[@"CIO_CDP_PORT"];
  if (debugPort != nil) {
    NSScanner *scanner = [NSScanner scannerWithString:debugPort];
    scanner.charactersToBeSkipped = nil;
    int port = 0;
    if ([scanner scanInt:&port] && scanner.isAtEnd &&
        (port == 0 || (port >= 1024 && port <= 65535))) {
      settings.remote_debugging_port = port;
    } else {
      fprintf(stderr, "[cef] invalid CIO_CDP_PORT; remote debugging disabled\n");
    }
  }
#endif
  // Derive Chrome's reduced product version from the bundled runtime. Leave
  // platform tokens and UA Client Hints to Chromium, without JS spoofing.
  CefString(&settings.user_agent_product).FromString(
      "Chrome/" + std::to_string(CHROME_VERSION_MAJOR) + ".0.0.0");
  // CEF 120+ protects root_cache_path with a process-singleton lock. Set it
  // explicitly instead of relying on the platform default so every isolated
  // verification run (and the production profile) owns a deterministic,
  // writable lock location. Chrome bootstrap uses its default profile child
  // under this root; keep the existing storage configuration for old profiles.
  CefString(&settings.root_cache_path).FromString(dataDirectory.UTF8String);
  CefString(&settings.cache_path).FromString(cachePath.UTF8String);
  CefString(&settings.log_file)
      .FromString([logDirectory stringByAppendingPathComponent:@"cef.log"].UTF8String);

  CefRefPtr<CioApp> app = new CioApp();

  const BOOL initialized = CefInitialize(main_args, settings, app.get(), nullptr);
  if (!initialized) {
    gState = RuntimeState::kFailed;
    if (error != nullptr) {
      *error = [NSError errorWithDomain:@"Cio.CEF"
                                   code:2
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"CefInitialize() returned false."
                               }];
    }
    fprintf(stderr, "[cef] CefInitialize failed\n");
    return NO;
  }

  gState = RuntimeState::kInitialized;
  gVersionString =
      [NSString stringWithFormat:@"CEF %s (Chromium %d.%d.%d.%d)", CEF_VERSION,
                                 CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR,
                                 CHROME_VERSION_BUILD, CHROME_VERSION_PATCH];
  fprintf(stderr, "[cef] initialized\n");
  return YES;
}

+ (BOOL)openChromeSettingsURL:(NSURL *)url {
  NSAssert(NSThread.isMainThread, @"Chrome settings must open on the CEF UI thread.");
  if (gState != RuntimeState::kInitialized ||
      ![url.scheme.lowercaseString isEqualToString:@"chrome"] ||
      ![url.host.lowercaseString isEqualToString:@"settings"]) return NO;
  return GetChromeSettingsClient()->Open(url.absoluteString.UTF8String);
}

+ (BOOL)hasLiveChromeSettingsBrowsers {
  return gChromeSettingsClient && gChromeSettingsClient->HasLiveBrowsers();
}

+ (void)closeChromeSettingsWithCompletion:(void (^)(void))completion {
  NSAssert(NSThread.isMainThread, @"Chrome settings must close on the CEF UI thread.");
  if (gChromeSettingsClient) gChromeSettingsClient->CloseAll(completion);
  else completion();
}

+ (void)flushCookiesWithCompletion:(void (^)(BOOL))completion {
  NSAssert(NSThread.isMainThread, @"Cookies must be flushed on the CEF UI thread.");
  if (gState != RuntimeState::kInitialized) {
    completion(YES);
    return;
  }
  CefRefPtr<CefCookieManager> manager = CefCookieManager::GetGlobalManager(nullptr);
  if (!manager || !manager->FlushStore(new CookieFlushCompletion(completion))) {
    fprintf(stderr, "[cef] unable to flush cookie storage\n");
    completion(NO);
  }
}

+ (void)shutdown {
  if (gState != RuntimeState::kInitialized) {
    return;
  }
  NSAssert(NSThread.isMainThread,
           @"CefShutdown() must be called on the main thread.");
  NSAssert(!self.hasLiveChromeSettingsBrowsers,
           @"Chrome settings must reach OnBeforeClose before CefShutdown.");
  gChromeSettingsClient = nullptr;
  gState = RuntimeState::kNotInitialized;
  CefShutdown();
  fprintf(stderr, "[cef] shutdown complete\n");
}

+ (BOOL)isInitialized {
  return gState == RuntimeState::kInitialized;
}

+ (NSString *)versionString {
  return gVersionString;
}

+ (void)doMessageLoopWork {
  if (gState != RuntimeState::kInitialized) {
    return;
  }
  CefDoMessageLoopWork();
}

+ (void)scheduleMessagePumpWorkAfter:(double)delay {
  if (gState != RuntimeState::kInitialized) {
    return;
  }
  if (delay <= 0) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [ChromiumProcessHost doMessageLoopWork];
    });
    return;
  }
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [ChromiumProcessHost doMessageLoopWork];
      });
}

@end

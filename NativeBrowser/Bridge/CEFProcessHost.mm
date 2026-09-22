//
//  CEFProcessHost.mm
//  NativeBrowser
//
//  Objective-C++ implementation of the CEF lifecycle boundary.
//
//  On macOS the CEF framework must be loaded at runtime from the app bundle
//  (CefScopedLibraryLoader) instead of being linked directly; that is a
//  requirement of the Chromium sandbox implementation and it is how the CEF
//  binary distribution expects client applications to start up.
//

#import "CEFProcessHost.h"

#include <cstdio>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_command_line.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

/// Minimal CefApp implementation.
///
/// Milestone 0 only needs a valid CefApp to hand to CefInitialize(); browser
/// process handlers (context initialization, browser creation) arrive with the
/// first Chromium view in Milestone 1.
class NativeBrowserApp final : public CefApp,
                              public CefBrowserProcessHandler {
 public:
  NativeBrowserApp() = default;

  // CefApp
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnBeforeCommandLineProcessing(
      const CefString &process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    // Keep the default Chromium command line for now. Any switch added here
    // must be justified and documented; see ARCHITECTURE.md section 33.
  }

  // CefBrowserProcessHandler
  ///
  /// The external message pump contract: CEF asks the client to run
  /// CefDoMessageLoopWork() now (delay_ms <= 0) or after |delay_ms|. Ignoring
  /// this leaves delayed UI-thread work - including browser destruction -
  /// unprocessed, so the request is turned into a scheduled pump on the main
  /// run loop.
  void OnScheduleMessagePumpWork(int64_t delay_ms) override;

 private:
  IMPLEMENT_REFCOUNTING(NativeBrowserApp);
  DISALLOW_COPY_AND_ASSIGN(NativeBrowserApp);
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
/// <NativeBrowser.app>/Contents/Frameworks. Must happen before the first CEF
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
          errorWithDomain:@"NativeBrowser.CEF"
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
      NSProcessInfo.processInfo.environment[@"NATIVEBROWSER_DATA_DIR"];
  if (override.length > 0) {
    return override;
  }
  NSArray<NSString *> *paths =
      NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                          NSUserDomainMask, YES);
  NSString *base = paths.firstObject ?: NSHomeDirectory();
  return [base stringByAppendingPathComponent:@"NativeBrowser"];
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

void NativeBrowserApp::OnScheduleMessagePumpWork(int64_t delay_ms) {
  if (delay_ms <= 0) {
    // Work is pending right now; a zero-delay hop keeps the ordering correct
    // without spinning the run loop.
    [CEFProcessHost scheduleMessagePumpWorkAfter:0];
    return;
  }
  [CEFProcessHost scheduleMessagePumpWorkAfter:delay_ms / 1000.0];
}

@implementation CEFProcessHost

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
  // executable (see NativeBrowser/Helper), this is a safety net.
  return CefExecuteProcess(main_args, nullptr, nullptr);
}

+ (BOOL)startWithError:(NSError **)error {
  if (gState == RuntimeState::kInitialized) {
    return YES;
  }
  if (gState == RuntimeState::kFailed) {
    if (error != nullptr) {
      *error = [NSError errorWithDomain:@"NativeBrowser.CEF"
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
  settings.persist_session_cookies = false;
  settings.remote_debugging_port = 0;
  // CEF 120+ protects root_cache_path with a process-singleton lock. Set it
  // explicitly instead of relying on the platform default so every isolated
  // verification run (and the production profile) owns a deterministic,
  // writable lock location. cache_path remains the profile-specific child
  // used by this browser instance.
  CefString(&settings.root_cache_path).FromString(dataDirectory.UTF8String);
  CefString(&settings.cache_path).FromString(cachePath.UTF8String);
  CefString(&settings.log_file)
      .FromString([logDirectory stringByAppendingPathComponent:@"cef.log"].UTF8String);

  CefRefPtr<NativeBrowserApp> app = new NativeBrowserApp();

  const BOOL initialized = CefInitialize(main_args, settings, app.get(), nullptr);
  if (!initialized) {
    gState = RuntimeState::kFailed;
    if (error != nullptr) {
      *error = [NSError errorWithDomain:@"NativeBrowser.CEF"
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

+ (void)shutdown {
  if (gState != RuntimeState::kInitialized) {
    return;
  }
  NSAssert(NSThread.isMainThread,
           @"CefShutdown() must be called on the main thread.");
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
      [CEFProcessHost doMessageLoopWork];
    });
    return;
  }
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [CEFProcessHost doMessageLoopWork];
      });
}

@end

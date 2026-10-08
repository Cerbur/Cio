#import "ChromiumProcessHost.h"
#import <AppKit/AppKit.h>
#import "CioNativeExports.h"
#include <string>
#include <vector>

namespace {
BOOL initialized = NO;
NSString* EngineDirectory() {
  NSString* custom = NSProcessInfo.processInfo.environment[@"CIO_DATA_DIR"];
  if (custom.length) return custom;
  return [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
      NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"Cio"];
}
BOOL PrepareProfile(NSString* root, NSError** error) {
  NSFileManager* files = NSFileManager.defaultManager;
  NSString* profile = [root stringByAppendingPathComponent:@"Chromium"];
  NSString* finalProfile = [profile stringByAppendingPathComponent:@"Default"];
  if ([files fileExistsAtPath:finalProfile]) return YES;
  NSString* legacy = [root stringByAppendingPathComponent:@"CEF"];
  NSString* defaultProfile = [legacy stringByAppendingPathComponent:@"Default"];
  if (![files fileExistsAtPath:[defaultProfile stringByAppendingPathComponent:@"Preferences"]]) defaultProfile = legacy;
  if (![files createDirectoryAtPath:profile withIntermediateDirectories:YES attributes:nil error:error]) return NO;
  NSString* lock = [root stringByAppendingPathComponent:@"SingletonLock"];
  NSString* owner = [files destinationOfSymbolicLinkAtPath:lock error:nullptr];
  pid_t ownerPID = (pid_t)[owner componentsSeparatedByString:@"-"].lastObject.intValue;
  if (ownerPID > 0 && [NSRunningApplication runningApplicationWithProcessIdentifier:ownerPID]) {
    if (error) *error = [NSError errorWithDomain:@"CioChromium" code:2 userInfo:@{
        NSLocalizedDescriptionKey: @"请先退出正在使用旧 CEF 数据目录的 Cio，再迁移浏览器资料。"}];
    return NO;
  }
  // Copy once, preserving the CEF profile. Chromium uses its normal encrypted
  // cookie/database migration; no credentials are read or logged by Cio.
  if ([files fileExistsAtPath:[defaultProfile stringByAppendingPathComponent:@"Preferences"]]) {
    NSString* pending = [profile stringByAppendingPathComponent:@"Default.pending"];
    if ([files fileExistsAtPath:pending]) [files removeItemAtPath:pending error:error];
    if (![files copyItemAtPath:defaultProfile toPath:pending error:error]) return NO;
    for (NSString* name in @[@"SingletonLock", @"SingletonCookie", @"SingletonSocket"])
      [files removeItemAtPath:[pending stringByAppendingPathComponent:name] error:nullptr];
    if (![files moveItemAtPath:pending toPath:finalProfile error:error]) return NO;
  }
  return YES;
}
}

@implementation ChromiumProcessHost
+ (NSString*)backendIdentifier { return @"chromium-native"; }
+ (BOOL)isInitialized { return initialized; }
+ (NSString*)versionString {
  if (!initialized) return nil;
  NSString* path = [NSBundle.mainBundle.privateFrameworksPath
      stringByAppendingPathComponent:@"Chromium Framework.framework"];
  NSString* version = [[NSBundle bundleWithPath:path] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  return [NSString stringWithFormat:@"Chromium %@ (native)", version ?: @"unknown"];
}
+ (int)executeSubprocess {
  BOOL child = NO;
  for (NSString* value in NSProcessInfo.processInfo.arguments)
    if ([value hasPrefix:@"--type="]) child = YES;
  if (!child) return -1;
  std::vector<std::string> arguments;
  for (NSString* value in NSProcessInfo.processInfo.arguments) arguments.emplace_back(value.UTF8String);
  std::vector<const char*> argv;
  for (const auto& value : arguments) argv.push_back(value.c_str());
  return CioNativeStart(static_cast<int>(argv.size()), argv.data());
}
+ (BOOL)startWithError:(NSError**)error {
  if (initialized) return YES;
  NSString* root = EngineDirectory();
  if (!PrepareProfile(root, error)) return NO;
  std::vector<std::string> arguments;
  for (NSString* value in NSProcessInfo.processInfo.arguments) arguments.emplace_back(value.UTF8String);
  arguments.emplace_back("--cio-embedded-browser");
  arguments.emplace_back("--no-startup-window");
  arguments.emplace_back("--no-first-run");
  arguments.emplace_back("--no-default-browser-check");
  arguments.emplace_back("--user-data-dir=" + std::string([root stringByAppendingPathComponent:@"Chromium"].UTF8String));
  std::vector<const char*> argv;
  for (const auto& value : arguments) argv.push_back(value.c_str());
  int result = CioNativeStart(static_cast<int>(argv.size()), argv.data());
  initialized = result == 0 && CioNativeIsInitialized();
  if (!initialized) {
    CioNativeShutdown();
    if (error) *error = [NSError errorWithDomain:@"CioChromium" code:result ?: -1
        userInfo:@{NSLocalizedDescriptionKey: @"Chromium 初始化失败，请检查引擎日志。"}];
  }
  return initialized;
}
+ (void)shutdown { if (initialized) { initialized = NO; CioNativeShutdown(); } }
+ (void)doMessageLoopWork { if (initialized) CioNativePump(); }
+ (void)flushCookiesWithCompletion:(void (^)(BOOL))completion { CioNativeFlushCookies(completion); }
+ (void)setDarkAppearance:(BOOL)dark { if (initialized) CioNativeSetDarkAppearance(dark); }
+ (BOOL)hasLiveChromeSettingsBrowsers { return NO; }
+ (void)closeChromeSettingsWithCompletion:(void (^)(void))completion { completion(); }
+ (BOOL)openChromeSettingsURL:(NSURL*)url {
  if (!initialized || ![url.scheme isEqualToString:@"chrome"] || ![url.host isEqualToString:@"settings"]) return NO;
  [NSNotificationCenter.defaultCenter postNotificationName:@"CioOpenChromeSettings" object:url];
  return YES;
}
@end

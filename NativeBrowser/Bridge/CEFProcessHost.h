//
//  CEFProcessHost.h
//  NativeBrowser
//
//  Application-scoped host for the Chromium Embedded Framework lifecycle.
//
//  This is the only place in the project that decides when CEF starts and
//  stops. SwiftUI views must never own CEF lifecycle logic (ARCHITECTURE.md
//  section 40, constraint 8).
//
//  No CEF C++ type is exposed through this header; Swift only ever sees
//  NSObject, NSString, NSError and a handful of scalars.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CEFProcessHost : NSObject

/// CEF sub-process hand-off.
///
/// Chromium starts renderer/GPU/utility processes by running the dedicated
/// helper executable inside "NativeBrowser Helper*.app" with a
/// `--type=<process>` switch (see NativeBrowser/Helper). This call keeps the
/// browser binary correct if it is ever launched that way instead, and it must
/// run before any AppKit or SwiftUI work happens.
///
/// @return The exit code to terminate with when the current process is a CEF
///         sub-process, or -1 when this is the main browser process and
///         startup should continue.
+ (int)executeSubprocess;

/// Initializes CEF for the browser process. Must be called on the main thread
/// before the application's run loop starts.
///
/// Named -start... rather than -initialize... to avoid colliding with
/// NSObject's +initialize.
///
/// Calling this more than once is a no-op.
- (instancetype)init NS_UNAVAILABLE;
+ (BOOL)startWithError:(NSError *_Nullable *_Nullable)error;

/// Shuts CEF down. Must be called on the main thread, after all browser
/// instances have been closed and before the process exits. Idempotent.
+ (void)shutdown;

/// Whether CefInitialize() has completed successfully.
@property(class, nonatomic, readonly) BOOL isInitialized;

/// CEF/Chromium version string reported by the loaded framework.
@property(class, nonatomic, readonly, nullable) NSString *versionString;

/// Pumps the CEF message loop once. Safe to call when CEF is not initialized.
+ (void)doMessageLoopWork;

/// Schedules a CEF message loop pump on the main run loop. Called by the
/// CefBrowserProcessHandler when CEF needs work done.
+ (void)scheduleMessagePumpWorkAfter:(double)delay;

@end

NS_ASSUME_NONNULL_END

//
//  ChromiumProcessHost.h
//  Cio
//
//  Application-scoped browser-engine lifecycle interface.
//
//  This is the only place in the project that decides when the engine starts and
//  stops. SwiftUI views must never own engine lifecycle logic (ARCHITECTURE.md
//  section 40, constraint 8).
//
//  No Chromium C++ type is exposed through this header; Swift only ever sees
//  NSObject, NSString, NSError and a handful of scalars.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ChromiumProcessHost : NSObject

/// Backend compiled into this build: `chromium-native`.
@property(class, nonatomic, readonly) NSString *backendIdentifier;

/// Runs Chromium when launched as a renderer/GPU/utility process. Normal
/// launches return -1. Standard Chromium helper applications are bundled with
/// the engine and do not link SwiftUI or create a Cio workspace.
+ (int)executeSubprocess;

/// Initializes Chromium for the browser process. Must be called on the main thread
/// before the application's run loop starts.
///
/// Named -start... rather than -initialize... to avoid colliding with
/// NSObject's +initialize.
///
/// Calling this more than once is a no-op.
- (instancetype)init NS_UNAVAILABLE;
+ (BOOL)startWithError:(NSError *_Nullable *_Nullable)error;

/// Shuts Chromium down. Must be called on the main thread, after all browser
/// instances have been closed and before the process exits. Idempotent.
+ (void)shutdown;

/// Asynchronously flushes Chromium's shared cookie store. Keep pumping Chromium
/// until completion, then schedule shutdown outside the Chromium callback stack.
+ (void)flushCookiesWithCompletion:(void (^)(BOOL success))completion;

/// Requests a managed Chrome Settings tab in Cio using its shared profile.
+ (BOOL)openChromeSettingsURL:(NSURL *)url;
@property(class, nonatomic, readonly) BOOL hasLiveChromeSettingsBrowsers;
+ (void)closeChromeSettingsWithCompletion:(void (^)(void))completion;

/// Keeps Chromium's own theme in sync with the host window's effective AppKit
/// appearance. Page media queries are updated separately per browser.
+ (void)setDarkAppearance:(BOOL)dark;

/// Whether Chromium initialization has completed successfully.
@property(class, nonatomic, readonly) BOOL isInitialized;

/// Chromium version string reported by the loaded framework.
@property(class, nonatomic, readonly, nullable) NSString *versionString;

/// Drains pending Chromium tasks on Cio's AppKit run loop. Safe to call when Chromium is not initialized.
+ (void)doMessageLoopWork;

@end

NS_ASSUME_NONNULL_END

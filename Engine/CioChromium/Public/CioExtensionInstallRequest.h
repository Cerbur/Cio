#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A single Chromium installation decision. The engine owns the prompt and
/// callback; the shell only presents its permission text and returns a choice.
/// Posted as the object of CioExtensionInstallRequested on the main thread.
NS_SWIFT_UI_ACTOR
__attribute__((visibility("default")))
@interface CioExtensionInstallRequest : NSObject
@property(nonatomic, readonly, copy) NSString *extensionName;
@property(nonatomic, readonly, copy) NSString *permissionsHeading;
/// Each entry includes Chromium's permission message and all its details.
@property(nonatomic, readonly, copy) NSArray<NSString *> *permissions;
@property(nonatomic, readonly, copy) NSString *acceptLabel;
@property(nonatomic, readonly, copy) NSString *cancelLabel;
@property(nonatomic, readonly, weak) NSWindow *parentWindow;
/// KVO compliant; the engine enables acceptance after input protection ends.
@property(nonatomic, readonly) BOOL canAccept;
- (instancetype)init NS_UNAVAILABLE;
- (void)didPresentInWindow:(NSWindow *)window;
- (void)accept;
- (void)cancel;
/// CioExtensionInstallFinished is posted for cancellation, acceptance or loss
/// of the originating tab/profile. Choices are resolved exactly once.
@end

NS_ASSUME_NONNULL_END

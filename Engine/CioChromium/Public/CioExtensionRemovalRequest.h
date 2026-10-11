#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Chromium retains uninstall policy, reporting and the original delegate.
NS_SWIFT_UI_ACTOR
__attribute__((visibility("default")))
@interface CioExtensionRemovalRequest : NSObject
@property(nonatomic, readonly, copy) NSString *extensionName;
@property(nonatomic, readonly, copy) NSString *message;
@property(nonatomic, readonly, copy, nullable) NSString *reportAbuseLabel;
@property(nonatomic, readonly, weak, nullable) NSWindow *parentWindow;
@property(nonatomic, readonly) BOOL canAccept;
- (instancetype)init NS_UNAVAILABLE;
- (void)didPresentInWindow:(NSWindow *)window;
- (void)acceptWithReportAbuse:(BOOL)reportAbuse NS_SWIFT_NAME(accept(reportAbuse:));
- (void)cancel;
/// Main-thread notifications use this request as their object:
/// CioExtensionRemovalRequested and CioExtensionRemovalFinished.
@end

NS_ASSUME_NONNULL_END

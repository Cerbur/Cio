#import <AppKit/AppKit.h>
#include "chrome/browser/ui/cio/CioWindowHooks.h"

// AppKit actions remain owned by Cio's SwiftUI shell. Chromium's window adapter
// uses this small router instead of importing Mori's SwiftUI root or window.
@interface CioRoot : NSObject
@end
@implementation CioRoot
+ (BOOL)handleShortcutEvent:(NSEvent *)event {
  if (!(event.modifierFlags & NSEventModifierFlagCommand)) return NO;
  return [NSApp.mainMenu performKeyEquivalent:event];
}
+ (void)focusOmnibox {
  [NSNotificationCenter.defaultCenter postNotificationName:@"CioFocusAddress" object:nil];
}
+ (void)showTabSearch {
  [NSNotificationCenter.defaultCenter postNotificationName:@"CioShowTabSearch" object:nil];
}
+ (void)showNativeNotice:(NSString *)message icon:(NSString *)icon {
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"Cio";
  alert.informativeText = message;
  if (NSWindow* window = cio::CioMainWindow()) [alert beginSheetModalForWindow:window completionHandler:nil];
}
+ (void)shareURL:(NSString *)url title:(NSString *)title {
  NSURL* target = [NSURL URLWithString:url];
  NSView* view = cio::CioMainWindow().contentView;
  if (target && view) [[[NSSharingServicePicker alloc] initWithItems:@[target]]
      showRelativeToRect:view.bounds ofView:view preferredEdge:NSMaxYEdge];
}
+ (void)toggleBookmarkForURL:(NSString *)url title:(NSString *)title {
  [NSNotificationCenter.defaultCenter postNotificationName:@"CioBookmarkURL" object:url userInfo:@{@"title": title ?: @""}];
}
+ (void)showQRCodeForURL:(NSString *)url title:(NSString *)title {
  [self showNativeNotice:@"二维码分享尚未接入。" icon:@"qrcode"];
}
+ (void)translateURL:(NSString *)url {
  [self showNativeNotice:@"页面翻译面板尚未接入。" icon:@"globe"];
}
+ (void)translateText:(NSString *)text {
  [self showNativeNotice:@"选区翻译面板尚未接入。" icon:@"globe"];
}
@end

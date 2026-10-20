#import <AppKit/AppKit.h>
#include "chrome/browser/ui/cio/CioWindowHooks.h"
#include "chrome/browser/ui/cio/CioMenuKeyEquivalent.h"

// AppKit actions remain owned by Cio's SwiftUI shell. Chromium's window adapter
// uses this small router instead of importing Mori's SwiftUI root or window.
@interface CioRoot : NSObject
@end
@implementation CioRoot
+ (BOOL)handleShortcutEvent:(NSEvent *)event {
  if (cio::PerformRecentTabSwitcherArrow(event)) return YES;
  const BOOL inspectorFunctionKey =
      [event.charactersIgnoringModifiers isEqualToString:[NSString stringWithFormat:@"%C", static_cast<unichar>(NSF12FunctionKey)]] &&
      !(event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                              NSEventModifierFlagControl | NSEventModifierFlagShift));
  const BOOL tabTraversal =
      (event.modifierFlags & NSEventModifierFlagControl) &&
      !(event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) &&
      ([event.charactersIgnoringModifiers isEqualToString:@"\t"] ||
       [event.charactersIgnoringModifiers isEqualToString:@"\x19"]);
  if (!(event.modifierFlags & NSEventModifierFlagCommand) && !inspectorFunctionKey && !tabTraversal) return NO;
  return cio::PerformMenuKeyEquivalent(NSApp.mainMenu, event);
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

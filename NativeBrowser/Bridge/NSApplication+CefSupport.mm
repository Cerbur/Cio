//
//  NSApplication+CefSupport.mm
//  NativeBrowser
//
//  CEF requires the NSApplication instance to implement CefAppProtocol: it
//  exposes whether -sendEvent: is on the stack, which Chromium needs in order to
//  dispatch native keyboard and IME events synchronously (ARCHITECTURE.md
//  sections 18 and 19). Without it Chromium raises
//  "-[NSApplication isHandlingSendEvent]: unrecognized selector".
//
//  CEF's sample applications subclass NSApplication for this. A SwiftUI
//  application cannot: SwiftUI owns the application object and CEF creates it
//  during CefInitialize(), before the SwiftUI App is started, so NSPrincipalClass
//  is not consulted. The protocol is therefore implemented on NSApplication
//  itself and -sendEvent: is wrapped once, which is equivalent to CEF's
//  reference implementation.
//

#import <AppKit/AppKit.h>

#import <objc/runtime.h>

#include "include/cef_application_mac.h"

namespace {

/// State of the single NSApplication instance's event dispatch.
BOOL gHandlingSendEvent = NO;

}  // namespace

@interface NSApplication (NativeBrowserCefSupport) <CefAppProtocol>
@end

@implementation NSApplication (NativeBrowserCefSupport)

+ (void)load {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    Method original = class_getInstanceMethod(self, @selector(sendEvent:));
    Method replacement =
        class_getInstanceMethod(self, @selector(nb_cef_sendEvent:));
    if (original != NULL && replacement != NULL) {
      method_exchangeImplementations(original, replacement);
    }
  });
}

- (BOOL)isHandlingSendEvent {
  return gHandlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  gHandlingSendEvent = handlingSendEvent;
}

/// Swizzled -sendEvent:. After the exchange above this calls the original
/// AppKit implementation.
- (void)nb_cef_sendEvent:(NSEvent *)event {
  CefScopedSendingEvent sendingEventScoper;
  [self nb_cef_sendEvent:event];
}

@end

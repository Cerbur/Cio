#ifndef CIO_MENU_KEY_EQUIVALENT_H_
#define CIO_MENU_KEY_EQUIVALENT_H_

#import <AppKit/AppKit.h>

namespace cio {

/// Only an active Swift switcher observer can acknowledge this synchronous
/// request. Outside that gesture, Control-arrows keep their normal behavior.
inline bool PerformRecentTabSwitcherArrow(NSEvent* event) {
  if (event.type != NSEventTypeKeyDown ||
      !(event.modifierFlags & NSEventModifierFlagControl) ||
      (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) ||
      (event.keyCode != 123 && event.keyCode != 124)) return false;
  NSMutableDictionary* request = [@{@"event": event, @"handled": @NO} mutableCopy];
  [NSNotificationCenter.defaultCenter postNotificationName:@"CioRecentTabSwitcherArrow"
      object:request];
  return [request[@"handled"] boolValue];
}

inline bool PerformMenuKeyEquivalent(NSMenu* menu, NSEvent* event) {
  const NSEventModifierFlags flags = event.modifierFlags;
  // Chromium/input sources can retain a plain tab in either character field
  // for Shift-Tab. AppKit's reverse-tab menu equivalent is NSBackTabCharacter.
  if (event.type == NSEventTypeKeyDown &&
      (flags & (NSEventModifierFlagControl | NSEventModifierFlagShift)) ==
          (NSEventModifierFlagControl | NSEventModifierFlagShift) &&
      !(flags & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) &&
      ([event.charactersIgnoringModifiers isEqualToString:@"\t"] ||
       [event.charactersIgnoringModifiers isEqualToString:@"\x19"])) {
    NSEvent* backtab = [NSEvent keyEventWithType:NSEventTypeKeyDown location:event.locationInWindow
        modifierFlags:flags timestamp:event.timestamp windowNumber:event.windowNumber context:nil
        characters:@"\x19" charactersIgnoringModifiers:@"\x19"
        isARepeat:event.isARepeat keyCode:event.keyCode];
    return [menu performKeyEquivalent:backtab] == YES;
  }
  if ([menu performKeyEquivalent:event]) return true;
  if (event.type != NSEventTypeKeyDown) return false;
  if (!(flags & NSEventModifierFlagCommand) ||
      (flags & (NSEventModifierFlagOption | NSEventModifierFlagControl))) return false;

  // Input sources and Chromium's native-event handoff can preserve the base
  // '=' in charactersIgnoringModifiers even when the actual character is '+'.
  // Match these plus variants to the primary Command-Equals menu shortcut.
  NSString* characters = event.characters;
  NSString* ignoring = event.charactersIgnoringModifiers;
  const bool plus = [characters isEqualToString:@"+"] || [characters isEqualToString:@"＋"] ||
      [ignoring isEqualToString:@"+"] || [ignoring isEqualToString:@"＋"] ||
      ((flags & NSEventModifierFlagShift) && [ignoring isEqualToString:@"="]);
  if (!plus) return false;
  NSEvent* equivalent = [NSEvent keyEventWithType:NSEventTypeKeyDown location:event.locationInWindow
      modifierFlags:flags & ~NSEventModifierFlagShift timestamp:event.timestamp
      windowNumber:event.windowNumber context:nil characters:@"=" charactersIgnoringModifiers:@"="
      isARepeat:event.isARepeat keyCode:event.keyCode];
  // Dispatch through the same validated native menu once. No direct browser
  // command, global keyboard monitor or second action on successful matches.
  return [menu performKeyEquivalent:equivalent] == YES;
}

}  // namespace cio

#endif  // CIO_MENU_KEY_EQUIVALENT_H_

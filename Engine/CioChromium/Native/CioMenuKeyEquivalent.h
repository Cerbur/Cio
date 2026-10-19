#ifndef CIO_MENU_KEY_EQUIVALENT_H_
#define CIO_MENU_KEY_EQUIVALENT_H_

#import <AppKit/AppKit.h>

namespace cio {

inline bool PerformMenuKeyEquivalent(NSMenu* menu, NSEvent* event) {
  if ([menu performKeyEquivalent:event]) return true;
  if (event.type != NSEventTypeKeyDown) return false;
  const NSEventModifierFlags flags = event.modifierFlags;
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

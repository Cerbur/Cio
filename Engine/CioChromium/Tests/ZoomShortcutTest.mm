#import <AppKit/AppKit.h>

#include "Engine/CioChromium/Native/CioMenuKeyEquivalent.h"

@interface ZoomShortcutTarget : NSObject
@property(nonatomic) NSInteger actions;
- (void)zoom:(id)sender;
@end

@implementation ZoomShortcutTarget
- (void)zoom:(id)sender { ++_actions; }
@end

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Private shortcut regression"];
    menu.autoenablesItems = NO;
    ZoomShortcutTarget* target = [[ZoomShortcutTarget alloc] init];
    NSMenuItem* zoom = [[NSMenuItem alloc] initWithTitle:@"Zoom In"
        action:@selector(zoom:) keyEquivalent:@"="];
    zoom.target = target;
    zoom.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [menu addItem:zoom];

    const NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    const NSEventModifierFlags shift = NSEventModifierFlagShift;
    struct Case {
      const char* name;
      NSString* characters;
      NSString* ignoring_modifiers;
      NSEventModifierFlags flags;
      unsigned short key_code;
      bool expected;
    } cases[] = {
      {"literal Command-Plus", @"+", @"+", cmd, 24, true},
      {"main keyboard Command-Plus", @"+", @"+", cmd | shift, 24, true},
      {"translated Command-Plus", @"+", @"=", cmd | shift, 24, true},
      {"shifted equals representation", @"=", @"=", cmd | shift, 24, true},
      {"full-width plus input", @"＋", @"＋", cmd | shift, 24, true},
      {"keypad Command-Plus", @"+", @"+", cmd | NSEventModifierFlagNumericPad, 69, true},
      {"repeat with Caps Lock", @"+", @"=", cmd | shift | NSEventModifierFlagCapsLock, 24, true},
      {"primary Command-Equals", @"=", @"=", cmd, 24, true},
      {"plain plus stays in page", @"+", @"+", shift, 24, false},
      {"Command-Option-Plus stays distinct", @"+", @"=", cmd | shift | NSEventModifierFlagOption, 24, false},
      {"Command-Control-Plus stays distinct", @"+", @"=", cmd | shift | NSEventModifierFlagControl, 24, false},
      {"unrelated Command-Minus", @"-", @"-", cmd, 27, false},
    };
    int failures = 0;
    for (const auto& test : cases) {
      NSEvent* event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
          modifierFlags:test.flags timestamp:0 windowNumber:0 context:nil
          characters:test.characters charactersIgnoringModifiers:test.ignoring_modifiers
          isARepeat:YES keyCode:test.key_code];
      const NSInteger before = target.actions;
      const bool handled = cio::PerformMenuKeyEquivalent(menu, event);
      const bool passed = handled == test.expected && target.actions - before == (test.expected ? 1 : 0);
      printf("%s: %s\n", passed ? "PASS" : "FAIL", test.name);
      failures += !passed;
    }
    // Native menu validation must still prevent a disabled command from firing.
    zoom.enabled = NO;
    NSEvent* disabled = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:cmd | shift timestamp:0 windowNumber:0 context:nil characters:@"+"
        charactersIgnoringModifiers:@"=" isARepeat:NO keyCode:24];
    const NSInteger before = target.actions;
    // AppKit can consume a disabled key equivalent without invoking its action.
    cio::PerformMenuKeyEquivalent(menu, disabled);
    const bool disabled_passed = target.actions == before;
    printf("%s: disabled native command stays disabled\n", disabled_passed ? "PASS" : "FAIL");
    failures += !disabled_passed;
    return failures ? 1 : 0;
  }
}

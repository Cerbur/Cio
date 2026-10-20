#import <AppKit/AppKit.h>
#include "Engine/CioChromium/Native/CioMenuKeyEquivalent.h"

@interface TabTraversalTarget : NSObject
@property(nonatomic) NSInteger nextCount;
@property(nonatomic) NSInteger previousCount;
- (void)next:(id)sender;
- (void)previous:(id)sender;
@end
@implementation TabTraversalTarget
- (void)next:(id)sender { ++_nextCount; }
- (void)previous:(id)sender { ++_previousCount; }
@end

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Tab traversal regression"];
    menu.autoenablesItems = NO;
    TabTraversalTarget* target = [[TabTraversalTarget alloc] init];
    const auto control = NSEventModifierFlagControl;
    const auto shift = NSEventModifierFlagShift;
    NSMenuItem* next = [[NSMenuItem alloc] initWithTitle:@"Next Tab" action:@selector(next:) keyEquivalent:@"\t"];
    next.target = target;
    next.keyEquivalentModifierMask = control;
    [menu addItem:next];
    NSMenuItem* previous = [[NSMenuItem alloc] initWithTitle:@"Previous Tab" action:@selector(previous:) keyEquivalent:@"\x19"];
    previous.target = target;
    previous.keyEquivalentModifierMask = control | shift;
    [menu addItem:previous];
    struct Case { NSString* text; NSString* ignoring; NSEventModifierFlags flags; int next; int previous; } cases[] = {
      {@"\t", @"\t", control, 1, 0},
      {@"\x19", @"\x19", control | shift, 0, 1},
      {@"\x19", @"\t", control | shift, 0, 1},
      {@"\t", @"\t", control | shift, 0, 1},
      {@"\t", @"\t", control | NSEventModifierFlagCapsLock, 1, 0},
      {@"\t", @"\t", 0, 0, 0},
      {@"\x19", @"\x19", shift, 0, 0},
      {@"\t", @"\t", control | NSEventModifierFlagOption, 0, 0},
      {@"\t", @"\t", control | NSEventModifierFlagCommand, 0, 0},
    };
    int failures = 0;
    for (const auto& test : cases) {
      NSEvent* event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
          modifierFlags:test.flags timestamp:0 windowNumber:0 context:nil characters:test.text
          charactersIgnoringModifiers:test.ignoring isARepeat:YES keyCode:48];
      const auto beforeNext = target.nextCount, beforePrevious = target.previousCount;
      cio::PerformMenuKeyEquivalent(menu, event);
      bool passed = target.nextCount - beforeNext == test.next && target.previousCount - beforePrevious == test.previous;
      printf("%s: native tab equivalent flags=%lu char=%u ignoring=%u\n", passed ? "PASS" : "FAIL",
          (unsigned long)test.flags, [test.text characterAtIndex:0], [test.ignoring characterAtIndex:0]);
      failures += !passed;
    }
    next.enabled = NO;
    const auto before = target.nextCount;
    cio::PerformMenuKeyEquivalent(menu, [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:control timestamp:0 windowNumber:0 context:nil characters:@"\t"
        charactersIgnoringModifiers:@"\t" isARepeat:NO keyCode:48]);
    failures += target.nextCount != before;
    printf("%s: disabled traversal command\n", target.nextCount == before ? "PASS" : "FAIL");
    auto arrowEvent = [](unsigned short key, NSEventModifierFlags flags, NSEventType type = NSEventTypeKeyDown) {
      return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:0
          windowNumber:0 context:nil characters:[NSString stringWithFormat:@"%C", NSLeftArrowFunctionKey]
          charactersIgnoringModifiers:[NSString stringWithFormat:@"%C", NSLeftArrowFunctionKey]
          isARepeat:YES keyCode:key];
    };
    bool inactive = !cio::PerformRecentTabSwitcherArrow(arrowEvent(123, control));
    failures += !inactive;
    printf("%s: Control-arrow is not consumed outside a switcher gesture\n", inactive ? "PASS" : "FAIL");
    __block int deliveries = 0;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:@"CioRecentTabSwitcherArrow"
        object:nil queue:nil usingBlock:^(NSNotification* note) {
          ++deliveries;
          NSMutableDictionary* request = note.object;
          request[@"handled"] = @YES;
        }];
    struct ArrowCase { unsigned short key; NSEventModifierFlags flags; NSEventType type; bool handled; } arrows[] = {
      {123, control, NSEventTypeKeyDown, true},
      {124, control, NSEventTypeKeyDown, true},
      {123, control | NSEventModifierFlagFunction | NSEventModifierFlagNumericPad, NSEventTypeKeyDown, true},
      {124, control | shift, NSEventTypeKeyDown, true},
      {123, 0, NSEventTypeKeyDown, false},
      {124, control | NSEventModifierFlagCommand, NSEventTypeKeyDown, false},
      {123, control | NSEventModifierFlagOption, NSEventTypeKeyDown, false},
      {125, control, NSEventTypeKeyDown, false},
      {123, control, NSEventTypeKeyUp, false},
    };
    for (const auto& test : arrows) {
      const int beforeDelivery = deliveries;
      bool handled = cio::PerformRecentTabSwitcherArrow(arrowEvent(test.key, test.flags, test.type));
      bool passed = handled == test.handled && deliveries - beforeDelivery == (test.handled ? 1 : 0);
      failures += !passed;
      printf("%s: scoped switcher arrow key=%u flags=%lu type=%lu\n", passed ? "PASS" : "FAIL",
          test.key, (unsigned long)test.flags, (unsigned long)test.type);
    }
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    bool released = !cio::PerformRecentTabSwitcherArrow(arrowEvent(124, control));
    failures += !released;
    printf("%s: ending the gesture restores normal Control-arrow dispatch\n", released ? "PASS" : "FAIL");
    return failures ? 1 : 0;
  }
}

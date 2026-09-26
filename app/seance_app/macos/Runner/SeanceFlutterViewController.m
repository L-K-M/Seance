#import "SeanceFlutterViewController.h"
#import <IOKit/hidsystem/IOLLEvent.h>

// Flutter marks shortcuts received by its text input plugin so an unhandled
// event can continue to the native menus. These selectors are runtime-only;
// the native keyboard regression checks them against the bundled engine.
@interface NSEvent (SeanceKeyEquivalent)
- (BOOL)isKeyEquivalent;
- (void)markAsKeyEquivalent;
@end

static NSEvent* SeanceNormalizeCommandModifier(NSEvent* event) {
  const NSEventModifierFlags flags = event.modifierFlags;
  const NSEventModifierFlags commandSides =
      NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK;
  if (!(flags & NSEventModifierFlagCommand) || (flags & commandSides)) {
    // Identity matters to Flutter's detection of redispatched events.
    return event;
  }

  // Tools such as Easydict send Command+C with only the aggregate Command
  // flag. Flutter 3.47 synchronizes modifiers from the left/right bits and
  // otherwise delivers a plain c instead of the shortcut.
  // Supply a deterministic side only when the source did not specify one.
  // Flutter releases it when the next event no longer carries Command.
  NSEvent* normalized =
      [NSEvent keyEventWithType:event.type
                      location:event.locationInWindow
                 modifierFlags:flags | NX_DEVICELCMDKEYMASK
                     timestamp:event.timestamp
                  windowNumber:event.windowNumber
                       context:nil
                    characters:event.characters ?: @""
   charactersIgnoringModifiers:event.charactersIgnoringModifiers ?: @""
                     isARepeat:event.isARepeat
                       keyCode:event.keyCode];
  if (normalized == nil) {
    return event;
  }
  if ([event respondsToSelector:@selector(isKeyEquivalent)] &&
      [event isKeyEquivalent] &&
      [normalized respondsToSelector:@selector(markAsKeyEquivalent)]) {
    [normalized markAsKeyEquivalent];
  }
  return normalized;
}

// Flutter exposes these Objective-C selectors at runtime, but not in its public
// headers. Keep this compatibility boundary here and exercise it against the
// bundled engine in scripts/test-macos-accessibility.sh.
@interface FlutterViewController (SeanceAccessibilityLifecycle)
- (void)notifySemanticsEnabledChanged;
@end

@interface FlutterEngine (SeanceAccessibilityLifecycle)
@property(nonatomic, readonly) BOOL semanticsEnabled;
@end

@interface NSView (SeanceAccessibilityLifecycle)
- (void)setPlatformNode:(void *)node;
@end

@implementation SeanceFlutterViewController

- (void)keyDown:(NSEvent*)event {
  [super keyDown:SeanceNormalizeCommandModifier(event)];
}

- (void)keyUp:(NSEvent*)event {
  [super keyUp:SeanceNormalizeCommandModifier(event)];
}

- (void)notifySemanticsEnabledChanged {
  if (!self.engine.semanticsEnabled) {
    [self invalidateAccessibilityTextFields];
  }
  [super notifySemanticsEnabledChanged];
}

- (void)dealloc {
  [self invalidateAccessibilityTextFields];
}

- (void)invalidateAccessibilityTextFields {
  if (!self.viewLoaded) {
    return;
  }
  Class textFieldClass = NSClassFromString(@"FlutterTextField");
  if (!textFieldClass ||
      ![textFieldClass instancesRespondToSelector:@selector(setPlatformNode:)]) {
    return;
  }

  // Flutter 3.47.3 destroys AccessibilityBridge::tree_ before id_wrapper_map_.
  // Detaching one native field can reenter AppKit while a sibling still points
  // through its delegate into the freed tree. Snapshot without querying any
  // accessibility data, then invalidate every field before the first detach.
  // The engine normally calls this same setter one field at a time.
  NSMutableArray<NSView *> *pending = [NSMutableArray arrayWithObject:self.view];
  NSMutableArray<NSView *> *fields = [NSMutableArray array];
  while (pending.count != 0) {
    NSView *view = pending.lastObject;
    [pending removeLastObject];
    if ([view isKindOfClass:textFieldClass]) {
      [fields addObject:view];
    }
    [pending addObjectsFromArray:view.subviews];
  }
  for (NSView *field in fields) {
    [field setPlatformNode:NULL];
  }
}

@end

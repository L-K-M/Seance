#import "SeanceFlutterViewController.h"

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

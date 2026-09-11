#import <Cocoa/Cocoa.h>
#import <FlutterMacOS/FlutterMacOS.h>
#import <objc/runtime.h>
#define FLUTTER_API_SYMBOL_PREFIX Fixture
#include "flutter/shell/platform/embedder/embedder.h"
#if SEANCE_USE_GUARD
#import "SeanceFlutterViewController.h"
#define FixtureBaseController SeanceFlutterViewController
#else
#define FixtureBaseController FlutterViewController
#endif

@interface FlutterEngine (Fixture)
@property(nonatomic) BOOL semanticsEnabled;
@property(nonatomic, readonly) NSTextView *textInputPlugin;
@end
@interface FlutterViewController (Fixture)
- (void)updateSemantics:(const FlutterSemanticsUpdate2 *)update;
@end
@interface NSTextField (Fixture)
- (void)startEditing;
@end
@interface NSTextView (Fixture)
@property(nonatomic, weak) NSTextField *client;
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result;
- (void)setEditingState:(NSDictionary *)state;
@end

@interface FixtureViewController : FixtureBaseController
@end
@implementation FixtureViewController
- (void)viewWillAppear {} // This fixture injects semantics without starting Dart.
@end

static NSArray<NSTextField *> *observedFields;
static NSHashTable<NSTextField *> *invalidatedFields;
static IMP originalRemoveFromSuperview;
static IMP originalSetPlatformNode;
static NSUInteger detachmentsWithLivePeer;

// Observe Flutter's own invalidation selector. Never inspect object memory,
// read through platform pointers, or dispatch editing during teardown.
static void observePlatformNode(id field, SEL selector, void *node) {
  if (node == nullptr) [invalidatedFields addObject:field];
  else [invalidatedFields removeObject:field];
  ((void (*)(id, SEL, void *))originalSetPlatformNode)(field, selector, node);
}

static void observeRemoval(id field, SEL selector) {
  for (NSTextField *peer in observedFields) {
    if (peer == field || peer.superview == nil) continue;
    if (![invalidatedFields containsObject:peer]) {
      detachmentsWithLivePeer++;
    }
  }
  ((void (*)(id, SEL))originalRemoveFromSuperview)(field, selector);
}

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static FlutterSemanticsNode2 makeNode(int32_t nodeId, const char *label,
                                     const char *value, FlutterSemanticsFlags *flags) {
  FlutterSemanticsNode2 node = {};
  node.struct_size = sizeof(node);
  node.id = nodeId;
  node.flags2 = flags;
  node.label = label;
  node.value = value;
  node.text_selection_base = -1;
  node.text_selection_extent = -1;
  node.platform_view_id = -1;
  node.rect = {0, 0, 200, 30};
  node.transform = {1, 0, 0, 0, 1, 0, 0, 0, 1};
  return node;
}

static void collectFields(id node, NSMutableArray<NSTextField *> *fields) {
  if ([node isKindOfClass:NSTextField.class]) {
    if (![fields containsObject:node]) [fields addObject:node];
  }
  if ([node isKindOfClass:NSTextFieldCell.class]) {
    NSTextField *field = (NSTextField *)[node controlView];
    if (![fields containsObject:field]) [fields addObject:field];
  }
  if ([node respondsToSelector:@selector(accessibilityChildren)]) {
    for (id child in [node accessibilityChildren]) {
      collectFields(child, fields);
    }
  }
}

static NSArray<NSTextField *> *nativeFields(NSView *view) {
  NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
  for (NSView *subview in view.subviews) collectFields(subview, fields);
  require(fields.count == 2, [NSString stringWithFormat:@"Two native text fields (found %lu)", fields.count]);
  for (NSTextField *field in fields) {
    require(field.superview != nil, @"Native text field attaches to Flutter view");
    require(field.frame.size.width > 0, @"Live native field resolves its semantics frame");
  }
  return fields;
}

static void checkDetached(NSArray<NSTextField *> *fields) {
  for (NSTextField *field in fields) {
    require(field.superview == nil, @"Native text field detaches after teardown");
    require([invalidatedFields containsObject:field], @"Flutter invalidates native field");
    require(NSEqualRects(field.frame, NSZeroRect), @"Detached field has invalidated platform node");
    [field startEditing];
    [field setAccessibilityFocused:YES];
  }
}

static void exerciseEditing(FlutterEngine *engine, NSWindow *window, NSTextField *field) {
  NSTextView *plugin = engine.textInputPlugin;
  FlutterMethodCall *setClient = [FlutterMethodCall methodCallWithMethodName:@"TextInput.setClient"
      arguments:@[@1, @{@"inputType": @{@"name": @"TextInputType.text"},
                        @"inputAction": @"TextInputAction.done"}]];
  [plugin handleMethodCall:setClient result:^(id result) {
    require(result == nil, @"Native input client initializes");
  }];
  [field startEditing];
  require(plugin.client == field, @"Native field becomes input plugin client");
  require([field.stringValue isEqualToString:@"alpha"], @"Native editor restores semantics text");
  require(NSEqualRanges(plugin.selectedRange, NSMakeRange(1, 2)), @"Native editor restores semantics selection");
  [plugin setEditingState:@{@"text": @"alpha updated", @"selectionBase": @2,
                           @"selectionExtent": @5, @"composingBase": @-1,
                           @"composingExtent": @-1}];
  require([field.stringValue isEqualToString:@"alpha updated"], @"Editing state updates native field text");
  require(NSEqualRanges(plugin.selectedRange, NSMakeRange(2, 3)), @"Editing state updates native selection");
  [window endEditingFor:nil];
  plugin.client = nil;
  [plugin handleMethodCall:[FlutterMethodCall methodCallWithMethodName:@"TextInput.clearClient"
                                                            arguments:nil]
                   result:^(id result) { require(result == nil, @"Native input client clears"); }];
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    FlutterEngine *engine = [[FlutterEngine alloc] initWithName:@"Semantics fixture"
                                                       project:nil];
    __weak FixtureViewController *weakController;
    NSArray<NSTextField *> *replacementFields;
    @autoreleasepool {
      FixtureViewController *controller = [[FixtureViewController alloc]
          initWithEngine:engine nibName:nil bundle:nil];
      require(!controller.viewLoaded, @"Initial semantics notification does not load the view");
      NSView *view = controller.view;
      require(view != nil, @"Flutter view loads");
      view.frame = NSMakeRect(0, 0, 640, 400);
      NSWindow *window = [[NSWindow alloc] initWithContentRect:view.frame
          styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
      window.contentViewController = controller;
      engine.semanticsEnabled = YES;

      FlutterSemanticsFlags rootFlags = {};
      rootFlags.struct_size = sizeof(rootFlags);
      FlutterSemanticsFlags textFlags = {};
      textFlags.struct_size = sizeof(textFlags);
      textFlags.is_text_field = true;
      textFlags.is_focused = kFlutterTristateFalse;
      textFlags.is_enabled = kFlutterTristateTrue;
      FlutterSemanticsNode2 root = makeNode(0, "Root", "", &rootFlags);
      FlutterSemanticsNode2 first = makeNode(1, "First field", "alpha", &textFlags);
      first.text_selection_base = 1;
      first.text_selection_extent = 3;
      FlutterSemanticsNode2 second = makeNode(2, "Second field", "beta", &textFlags);
      int32_t childIds[] = {1, 2};
      root.child_count = 2;
      root.children_in_traversal_order = childIds;
      root.children_in_hit_test_order = childIds;
      FlutterSemanticsNode2 *nodes[] = {&root, &first, &second};
      FlutterSemanticsUpdate2 update = {};
      update.struct_size = sizeof(update);
      update.node_count = 3;
      update.nodes = nodes;
      [controller updateSemantics:&update];

      NSArray<NSTextField *> *fields = nativeFields(view);
      NSLog(@"PASS: created two attached native text fields");

      Class fieldClass = [fields.firstObject class];
      invalidatedFields = [NSHashTable weakObjectsHashTable];
      SEL setNodeSelector = NSSelectorFromString(@"setPlatformNode:");
      Method setNodeMethod = class_getInstanceMethod(fieldClass, setNodeSelector);
      require(setNodeMethod != nullptr, @"Flutter provides expected invalidation selector");
      originalSetPlatformNode = method_setImplementation(setNodeMethod, (IMP)observePlatformNode);
      SEL removeSelector = @selector(removeFromSuperview);
      originalRemoveFromSuperview = class_getMethodImplementation(fieldClass, removeSelector);
      const char *encoding = method_getTypeEncoding(class_getInstanceMethod(fieldClass, removeSelector));
      require(class_addMethod(fieldClass, removeSelector, (IMP)observeRemoval, encoding),
              @"Install benign native field detachment observer");
      exerciseEditing(engine, window, fields.firstObject);
      NSLog(@"PASS: native editing restores and updates text and selection");
      observedFields = [fields copy];

      engine.semanticsEnabled = NO;
      observedFields = nil;
      checkDetached(fields);
      NSLog(@"PASS: both fields invalidate and ignore editing after semantics teardown");

      engine.semanticsEnabled = YES;
      [controller updateSemantics:&update];
      replacementFields = nativeFields(view);
      for (NSTextField *field in replacementFields) {
        require(![fields containsObject:field], @"Reenabled semantics creates fresh native fields");
      }
      exerciseEditing(engine, window, replacementFields.firstObject);
      NSLog(@"PASS: reenabled semantics creates fresh fields with working text and selection");
      observedFields = replacementFields;
      weakController = controller;
      window.contentViewController = nil;
      controller = nil;
    }
    require(weakController == nil, @"Controller deallocates while semantics remains enabled");
    observedFields = nil;
    checkDetached(replacementFields);
    NSLog(@"PASS: controller destruction invalidates and detaches both fields");
    NSLog(@"Teardown observations: %lu detachment(s) while an attached peer still has a platform node pointer",
          detachmentsWithLivePeer);
    require(detachmentsWithLivePeer == 0,
            @"All native text fields invalidate before the first field detaches");
  }
  return 0;
}

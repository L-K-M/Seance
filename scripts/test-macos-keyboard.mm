#import <Cocoa/Cocoa.h>
#import <FlutterMacOS/FlutterMacOS.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import <objc/runtime.h>
#define FLUTTER_API_SYMBOL_PREFIX Fixture
#include "flutter/shell/platform/embedder/embedder.h"
#include "flutter/shell/platform/embedder/test_utils/key_codes.g.h"
#if SEANCE_USE_CONTROLLER
#import "SeanceFlutterViewController.h"
#define FixtureController SeanceFlutterViewController
#else
#define FixtureController FlutterViewController
#endif

using namespace flutter::testing::keycodes;

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

@interface NSEvent (FixtureKeyEquivalent)
- (void)markAsKeyEquivalent;
- (BOOL)isKeyEquivalent;
@end

@interface FlutterEngine (FixtureLifecycle)
@property(nonatomic, readonly) BOOL running;
@end

@interface FlutterViewController (FixtureRedispatch)
- (BOOL)isDispatchingKeyEvent:(NSEvent *)event;
@end

// Leave the real controller, manager, and both native keyboard responders
// intact. Only the two outbound transports have an immediate framework sink.
@interface KeyboardFixtureEngine : FlutterEngine
- (instancetype)initFixture;
@property(nonatomic) NSMutableArray<NSDictionary *> *events;
@property(nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *pressed;
@property(nonatomic) NSMutableArray<NSEvent *> *nativeEvents;
@property(nonatomic) NSMutableArray<NSDictionary *> *channelEvents;
@property(nonatomic) BOOL frameworkHandlesEvents;
@end

@implementation KeyboardFixtureEngine
- (instancetype)initFixture {
  self = [super initWithName:@"Keyboard regression fixture" project:nil];
  if (self) {
    _events = [NSMutableArray array];
    _pressed = [NSMutableDictionary dictionary];
    _nativeEvents = [NSMutableArray array];
    _channelEvents = [NSMutableArray array];
    _frameworkHandlesEvents = YES;
  }
  return self;
}

- (void)sendKeyEvent:(const FlutterKeyEvent&)event
           callback:(FlutterKeyEventCallback)callback
           userData:(void *)userData {
  if (event.physical != 0) {
    if (event.type == kFlutterKeyEventTypeDown) {
      require(self.pressed[@(event.physical)] == nil, @"No duplicate key down");
      self.pressed[@(event.physical)] = @(event.logical);
    } else if (event.type == kFlutterKeyEventTypeUp) {
      require(self.pressed[@(event.physical)] != nil, @"No duplicate key up");
      [self.pressed removeObjectForKey:@(event.physical)];
    } else {
      require(self.pressed[@(event.physical)] != nil, @"Repeat keeps a pressed key");
    }
  }
  [self.events addObject:@{
    @"type": @(event.type), @"physical": @(event.physical),
    @"logical": @(event.logical), @"synthesized": @(event.synthesized),
    @"character": event.character ? @(event.character) : @"",
    @"pressed": [self.pressed copy],
  }];
  if (callback) callback(self.frameworkHandlesEvents, userData);
}

- (void)sendOnChannel:(NSString *)channel message:(NSData *)message
         binaryReply:(FlutterBinaryReply)reply {
  if ([channel isEqualToString:@"flutter/keyevent"]) {
    [self.channelEvents addObject:[[FlutterJSONMessageCodec sharedInstance] decode:message]];
    if (reply) reply([[FlutterJSONMessageCodec sharedInstance]
        encode:@{@"handled": @(self.frameworkHandlesEvents)}]);
    return;
  }
  if (reply) reply(nil);
}
@end

// These endpoints observe the real manager's unhandled-event handoff. They
// deliberately stop before native text editing, NSWindow, or menu dispatch;
// this proves the manager boundary, not a complete IME integration.
@interface UnhandledFixtureController : FixtureController
@property(nonatomic) NSMutableArray<NSEvent *> *textEvents;
@end

@implementation UnhandledFixtureController
- (BOOL)onTextInputKeyEvent:(NSEvent *)event {
  [self.textEvents addObject:event];
  return NO;
}
@end

@interface FixtureNextResponder : NSResponder
@property(nonatomic, weak) FlutterViewController *controller;
@property(nonatomic) NSMutableArray<NSEvent *> *events;
@end

@implementation FixtureNextResponder
- (void)recordEvent:(NSEvent *)event {
  require([self.controller isDispatchingKeyEvent:event],
          @"Real manager marks this exact event during next-responder dispatch");
  [self.events addObject:event];
}
- (void)keyDown:(NSEvent *)event {
  [self recordEvent:event];
}
- (void)keyUp:(NSEvent *)event {
  [self recordEvent:event];
}
@end

// Observe the real superclass ingress without replacing its implementation.
// This is confined to this process and checks event identity/metadata that the
// embedder intentionally omits from its outbound FlutterKeyEvent.
static IMP originalKeyDown;
static IMP originalKeyUp;
static void observeKeyDown(FlutterViewController *controller, SEL selector, NSEvent *event) {
  [((KeyboardFixtureEngine *)controller.engine).nativeEvents addObject:event];
  ((void (*)(id, SEL, NSEvent *))originalKeyDown)(controller, selector, event);
}
static void observeKeyUp(FlutterViewController *controller, SEL selector, NSEvent *event) {
  [((KeyboardFixtureEngine *)controller.engine).nativeEvents addObject:event];
  ((void (*)(id, SEL, NSEvent *))originalKeyUp)(controller, selector, event);
}

static NSEvent *keyEvent(NSEventType type, NSEventModifierFlags flags,
                        unsigned short keyCode = 8, NSString *characters = @"c",
                        BOOL repeat = NO) {
  return [NSEvent keyEventWithType:type location:NSMakePoint(12, 34)
      modifierFlags:flags timestamp:123.5 windowNumber:0 context:nil
      characters:characters charactersIgnoringModifiers:characters
      isARepeat:repeat keyCode:keyCode];
}

static BOOL metaPressed(NSDictionary *pressed) {
  return [pressed[@(kPhysicalMetaLeft)] isEqual:@(kLogicalMetaLeft)] ||
         [pressed[@(kPhysicalMetaRight)] isEqual:@(kLogicalMetaRight)];
}

static NSDictionary *lastCharacterEvent(KeyboardFixtureEngine *engine, uint64_t physical) {
  for (NSDictionary *event in engine.events.reverseObjectEnumerator) {
    if ([event[@"physical"] unsignedLongLongValue] == physical) return event;
  }
  require(NO, @"Real Flutter responder emitted the character key");
  return nil;
}

static void requireMetadata(NSEvent *original, NSEvent *forwarded) {
  require(original.type == forwarded.type &&
          NSEqualPoints(original.locationInWindow, forwarded.locationInWindow) &&
          original.timestamp == forwarded.timestamp &&
          original.windowNumber == forwarded.windowNumber &&
          [original.characters isEqualToString:forwarded.characters] &&
          [original.charactersIgnoringModifiers isEqualToString:forwarded.charactersIgnoringModifiers] &&
          original.isARepeat == forwarded.isARepeat &&
          original.keyCode == forwarded.keyCode,
          @"Normalization preserves native key metadata");
}

static void releaseWithPlainInput(FixtureController *controller,
                                  KeyboardFixtureEngine *engine) {
  NSEvent *plain = keyEvent(NSEventTypeKeyDown, 0, 0, @"a");
  [controller keyDown:plain];
  require(engine.nativeEvents.lastObject == plain, @"Plain input retains event identity");
  require(!metaPressed(lastCharacterEvent(engine, kPhysicalKeyA)[@"pressed"]),
          @"Subsequent plain input releases synthesized Command");
  [controller keyUp:keyEvent(NSEventTypeKeyUp, 0, 0, @"a")];
  require(engine.pressed.count == 0, @"No stuck keys after plain input");
}

static void checkPhysicalSides(FixtureController *controller,
                               KeyboardFixtureEngine *engine) {
  const NSEventModifierFlags cases[] = {
    NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK,
    NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK,
  };
  for (NSEventModifierFlags sides : cases) {
    NSEventModifierFlags flags = NSEventModifierFlagCommand | sides;
    NSEvent *down = keyEvent(NSEventTypeKeyDown, flags);
    [controller keyDown:down];
    require(engine.nativeEvents.lastObject == down,
            @"Existing Command side flags preserve event identity");
    NSDictionary *pressed = lastCharacterEvent(engine, kPhysicalKeyC)[@"pressed"];
    require((pressed[@(kPhysicalMetaLeft)] != nil) == ((sides & NX_DEVICELCMDKEYMASK) != 0) &&
            (pressed[@(kPhysicalMetaRight)] != nil) == ((sides & NX_DEVICERCMDKEYMASK) != 0),
            @"Real Flutter responder preserves left/right/both Command identity");
    NSEvent *up = keyEvent(NSEventTypeKeyUp, flags);
    [controller keyUp:up];
    require(engine.nativeEvents.lastObject == up,
            @"Physical Command key-up preserves event identity");
    releaseWithPlainInput(controller, engine);
  }
  NSLog(@"PASS: physical left/right/both Command identity");
}

static void checkRepeatAndKeyEquivalent(FixtureController *controller,
                                        KeyboardFixtureEngine *engine) {
  NSEvent *down = keyEvent(NSEventTypeKeyDown, NSEventModifierFlagCommand);
  [controller keyDown:down];
  NSEvent *normalized = engine.nativeEvents.lastObject;
  require(normalized != down, @"Aggregate-only Command copies the event");
  require(normalized.modifierFlags == (NSEventModifierFlagCommand | NX_DEVICELCMDKEYMASK),
          @"Missing Command side uses the left fallback");
  requireMetadata(down, normalized);
  [controller keyUp:keyEvent(NSEventTypeKeyUp, NSEventModifierFlagCommand)];
  // Reenter with an already normalized event: it must be forwarded as-is.
  [controller keyDown:normalized];
  require(engine.nativeEvents.lastObject == normalized, @"Normalization is idempotent");

  NSEvent *repeat = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSMakePoint(45, 67) modifierFlags:NSEventModifierFlagCommand
      timestamp:456.25 windowNumber:31 context:nil characters:@"C"
      charactersIgnoringModifiers:@"c" isARepeat:YES keyCode:8];
  require([repeat respondsToSelector:@selector(markAsKeyEquivalent)] &&
          [repeat respondsToSelector:@selector(isKeyEquivalent)],
          @"Bundled Flutter exposes its native key-equivalent marker");
  [repeat markAsKeyEquivalent];
  [controller keyDown:repeat];
  NSEvent *forwarded = engine.nativeEvents.lastObject;
  requireMetadata(repeat, forwarded);
  require([forwarded isKeyEquivalent], @"Flutter key-equivalent marker survives the copy");
  require([repeat isKeyEquivalent] && repeat.modifierFlags == NSEventModifierFlagCommand,
          @"Original marked event is unchanged");
  require([lastCharacterEvent(engine, kPhysicalKeyC)[@"type"] intValue] == kFlutterKeyEventTypeRepeat,
          @"Real Flutter responder preserves repeat events");
  NSEvent *up = keyEvent(NSEventTypeKeyUp, NSEventModifierFlagCommand);
  [controller keyUp:up];
  requireMetadata(up, engine.nativeEvents.lastObject);
  require(up.modifierFlags == NSEventModifierFlagCommand, @"Original key-up is unchanged");
  releaseWithPlainInput(controller, engine);
  NSLog(@"PASS: metadata, repeats, key-equivalent marker, and idempotence");
}

static void checkPhysicalShiftSequence(FixtureController *controller,
                                       KeyboardFixtureEngine *engine) {
  // The observed sequence: physical Shift is held when another process sends
  // Command+C carrying only the aggregate Command flag. Nothing is posted to
  // AppKit; these NSEvents enter the same controller methods directly.
  [controller flagsChanged:keyEvent(NSEventTypeFlagsChanged,
      NSEventModifierFlagShift | NX_DEVICELSHIFTKEYMASK | 0x100, 56, @"")];
  require(engine.pressed[@(kPhysicalShiftLeft)] != nil, @"Physical Shift starts pressed");
  [controller keyDown:keyEvent(NSEventTypeKeyDown, NSEventModifierFlagCommand)];
  require(metaPressed(lastCharacterEvent(engine, kPhysicalKeyC)[@"pressed"]),
          @"Shift-click sequence preserves injected Command on C");
  [controller keyUp:keyEvent(NSEventTypeKeyUp, NSEventModifierFlagCommand)];
  [controller flagsChanged:keyEvent(NSEventTypeFlagsChanged, 0x100, 56, @"")];
  NSEvent *plainC = keyEvent(NSEventTypeKeyDown, 0);
  [controller keyDown:plainC];
  require(engine.nativeEvents.lastObject == plainC, @"Plain C remains unchanged");
  NSDictionary *pressed = lastCharacterEvent(engine, kPhysicalKeyC)[@"pressed"];
  require(!metaPressed(pressed) && pressed[@(kPhysicalShiftLeft)] == nil &&
          pressed[@(kPhysicalShiftRight)] == nil,
          @"Shift release and subsequent plain C leave no modifiers pressed");
  [controller keyUp:keyEvent(NSEventTypeKeyUp, 0)];
  require(engine.pressed.count == 0, @"Shift-click sequence leaves no stuck keys");
  NSLog(@"PASS: physical Shift, aggregate Command+C, Shift release, plain C");
}

static void checkOtherModifiers(FixtureController *controller,
                                KeyboardFixtureEngine *engine) {
  const NSEventModifierFlags flags = NSEventModifierFlagShift | NX_DEVICERSHIFTKEYMASK |
      NSEventModifierFlagControl | NX_DEVICELCTLKEYMASK |
      NSEventModifierFlagOption | NX_DEVICERALTKEYMASK;
  NSEvent *plain = keyEvent(NSEventTypeKeyDown, flags);
  [controller keyDown:plain];
  require(engine.nativeEvents.lastObject == plain,
          @"Other modifier chords keep event identity without Command");
  [controller keyUp:keyEvent(NSEventTypeKeyUp, flags)];
  NSEvent *command = keyEvent(NSEventTypeKeyDown, flags | NSEventModifierFlagCommand);
  [controller keyDown:command];
  NSEvent *forwarded = engine.nativeEvents.lastObject;
  require((forwarded.modifierFlags & ~NX_DEVICELCMDKEYMASK) == command.modifierFlags,
          @"Normalizing Command preserves every unrelated modifier flag");
  NSDictionary *pressed = lastCharacterEvent(engine, kPhysicalKeyC)[@"pressed"];
  require(pressed[@(kPhysicalShiftRight)] != nil && pressed[@(kPhysicalControlLeft)] != nil &&
          pressed[@(kPhysicalAltRight)] != nil && metaPressed(pressed),
          @"Other physical modifier sides remain pressed in Flutter");
  [controller keyUp:keyEvent(NSEventTypeKeyUp, flags | NSEventModifierFlagCommand)];
  releaseWithPlainInput(controller, engine);
  NSLog(@"PASS: unrelated modifier flags and physical sides");
}

static void checkUnhandledDispatch(void) {
  KeyboardFixtureEngine *engine = [[KeyboardFixtureEngine alloc] initFixture];
  UnhandledFixtureController *controller = [[UnhandledFixtureController alloc]
      initWithEngine:engine nibName:nil bundle:nil];
  controller.textEvents = [NSMutableArray array];
  FixtureNextResponder *next = [[FixtureNextResponder alloc] init];
  next.controller = controller;
  next.events = [NSMutableArray array];
  controller.nextResponder = next;
  engine.frameworkHandlesEvents = NO;

  NSEvent *down = keyEvent(NSEventTypeKeyDown, NSEventModifierFlagCommand);
  [down markAsKeyEquivalent];
  [controller keyDown:down];
  NSEvent *forwarded = engine.nativeEvents.lastObject;
  require(controller.textEvents.count == 1 && next.events.count == 1 &&
          controller.textEvents.lastObject == forwarded && next.events.lastObject == forwarded,
          @"Unhandled Command key-down reaches both handoffs exactly once with the same event");
  require(forwarded != down && [forwarded isKeyEquivalent] &&
          forwarded.modifierFlags == (NSEventModifierFlagCommand | NX_DEVICELCMDKEYMASK),
          @"Unhandled handoff preserves normalized Command and the key-equivalent marker");
  requireMetadata(down, forwarded);
  require(down.modifierFlags == NSEventModifierFlagCommand && [down isKeyEquivalent],
          @"Unhandled dispatch leaves the original marked event unchanged");
  require(![controller isDispatchingKeyEvent:forwarded],
          @"Real manager clears its redispatch marker after key-down returns");
  require(metaPressed(lastCharacterEvent(engine, kPhysicalKeyC)[@"pressed"]),
          @"Unhandled Command+C still reaches Flutter with Meta pressed");

  NSEvent *up = keyEvent(NSEventTypeKeyUp, NSEventModifierFlagCommand);
  [controller keyUp:up];
  forwarded = engine.nativeEvents.lastObject;
  require(controller.textEvents.count == 2 && next.events.count == 2 &&
          controller.textEvents.lastObject == forwarded && next.events.lastObject == forwarded &&
          forwarded.type == NSEventTypeKeyUp,
          @"Unhandled key-up reaches both handoffs exactly once with the same event");
  requireMetadata(up, forwarded);
  require(forwarded != up && ![forwarded isKeyEquivalent] &&
          forwarded.modifierFlags == (NSEventModifierFlagCommand | NX_DEVICELCMDKEYMASK) &&
          up.modifierFlags == NSEventModifierFlagCommand,
          @"Unhandled key-up is normalized without changing its original event or marker");
  require(![controller isDispatchingKeyEvent:forwarded],
          @"Real manager clears its redispatch marker after key-up returns");
  require(engine.nativeEvents.count == 2 && engine.channelEvents.count == 2,
          @"Neither native ingress nor the channel responder receives duplicate events");

  engine.frameworkHandlesEvents = YES;
  releaseWithPlainInput(controller, engine);
  require(controller.textEvents.count == 2 && next.events.count == 2,
          @"Handled input bypasses both unhandled-event handoffs");
  require(!controller.viewLoaded && !engine.running,
          @"Unhandled-event checks start no native view or Dart application");
  NSLog(@"PASS: unhandled manager handoff, event identity, and redispatch marker lifecycle");
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    Method down = class_getInstanceMethod(FlutterViewController.class, @selector(keyDown:));
    Method up = class_getInstanceMethod(FlutterViewController.class, @selector(keyUp:));
    require(down && up, @"Bundled Flutter exposes keyboard ingress");
    originalKeyDown = method_setImplementation(down, (IMP)observeKeyDown);
    originalKeyUp = method_setImplementation(up, (IMP)observeKeyUp);

    KeyboardFixtureEngine *engine = [[KeyboardFixtureEngine alloc] initFixture];
    FixtureController *controller = [[FixtureController alloc]
        initWithEngine:engine nibName:nil bundle:nil];
    require(!controller.viewLoaded, @"Fixture starts no view or Dart application");
    NSEvent *commandC = keyEvent(NSEventTypeKeyDown, NSEventModifierFlagCommand);
    [controller keyDown:commandC];
    NSDictionary *character = lastCharacterEvent(engine, kPhysicalKeyC);
    require(metaPressed(character[@"pressed"]),
            @"Aggregate-only Command+C reaches Flutter with Meta pressed");
    require(commandC.modifierFlags == NSEventModifierFlagCommand,
            @"Original native event remains unchanged");
    [controller keyUp:keyEvent(NSEventTypeKeyUp, NSEventModifierFlagCommand)];
    releaseWithPlainInput(controller, engine);
    NSLog(@"PASS: aggregate-only Command+C and subsequent plain input");

    checkPhysicalSides(controller, engine);
    checkRepeatAndKeyEquivalent(controller, engine);
    checkPhysicalShiftSequence(controller, engine);
    checkOtherModifiers(controller, engine);

    // Replacing a controller keeps the engine's keyboard state. No window or
    // extra engine view is required to prove both ingress instances normalize.
    [controller keyDown:keyEvent(NSEventTypeKeyDown, NSEventModifierFlagCommand)];
    engine.viewController = nil;
    FixtureController *replacement = [[FixtureController alloc]
        initWithEngine:engine nibName:nil bundle:nil];
    [replacement keyUp:keyEvent(NSEventTypeKeyUp, NSEventModifierFlagCommand)];
    require(![engine.nativeEvents.lastObject isKeyEquivalent],
            @"An unmarked key-up does not acquire the key-equivalent marker");
    releaseWithPlainInput(replacement, engine);
    [replacement keyDown:keyEvent(NSEventTypeKeyDown, NSEventModifierFlagCommand, 9, @"v")];
    require(metaPressed(lastCharacterEvent(engine, kPhysicalKeyV)[@"pressed"]),
            @"Replacement controller normalizes Command+V as well");
    [replacement keyUp:keyEvent(NSEventTypeKeyUp, NSEventModifierFlagCommand, 9, @"v")];
    releaseWithPlainInput(replacement, engine);
    require(!controller.viewLoaded && !replacement.viewLoaded && !engine.running,
            @"All checks run without a window or Dart application");
    require(engine.channelEvents.count > 0, @"Real legacy channel responder also completes");
    NSLog(@"PASS: controller replacement, Command+V, both native responder transports");

    checkUnhandledDispatch();

    method_setImplementation(down, originalKeyDown);
    method_setImplementation(up, originalKeyUp);
  }
  return 0;
}

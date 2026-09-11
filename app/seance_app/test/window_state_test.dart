import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/window_state.dart';

void main() {
  group('WindowStateSnapshot', () {
    test('round-trips bounds and presentation flags through JSON', () {
      const snapshot = WindowStateSnapshot(
        bounds: Rect.fromLTWH(120, 80, 1440, 900),
        isMaximized: true,
        isFullScreen: false,
      );
      final restored = WindowStateSnapshot.fromJson(snapshot.toJson())!;
      expect(restored.bounds, const Rect.fromLTWH(120, 80, 1440, 900));
      expect(restored.isMaximized, isTrue);
      expect(restored.isFullScreen, isFalse);
    });

    test('negative positions survive (a window on a left-of-primary monitor)', () {
      const snapshot = WindowStateSnapshot(
        bounds: Rect.fromLTWH(-1920, -200, 1280, 800),
      );
      final restored = WindowStateSnapshot.fromJson(snapshot.toJson())!;
      expect(restored.bounds, const Rect.fromLTWH(-1920, -200, 1280, 800));
    });

    test('a snapshot without bounds keeps its flags', () {
      const snapshot = WindowStateSnapshot(isFullScreen: true);
      final restored = WindowStateSnapshot.fromJson(snapshot.toJson())!;
      expect(restored.bounds, isNull);
      expect(restored.isFullScreen, isTrue);
    });

    test('malformed JSON reads as nothing saved', () {
      expect(WindowStateSnapshot.fromJson(null), isNull);
      expect(WindowStateSnapshot.fromJson('not a map'), isNull);
      expect(WindowStateSnapshot.fromJson([1, 2, 3]), isNull);
    });

    test('garbage geometry drops the bounds but keeps the flags', () {
      for (final bad in <Map<String, Object?>>[
        {'x': 'left', 'y': 0, 'width': 800, 'height': 600},
        {'x': 0, 'y': 0, 'width': 800}, // height missing
        {'x': 0, 'y': 0, 'width': 0, 'height': 600},
        {'x': 0, 'y': 0, 'width': -800, 'height': 600},
        {'x': double.nan, 'y': 0, 'width': 800, 'height': 600},
        {'x': 0, 'y': double.infinity, 'width': 800, 'height': 600},
      ]) {
        final restored = WindowStateSnapshot.fromJson({
          ...bad,
          'isMaximized': true,
        })!;
        expect(restored.bounds, isNull, reason: '$bad');
        expect(restored.isMaximized, isTrue, reason: '$bad');
      }
    });

    test('non-bool flags read as false', () {
      final restored = WindowStateSnapshot.fromJson({
        'isMaximized': 'yes',
        'isFullScreen': 1,
      })!;
      expect(restored.isMaximized, isFalse);
      expect(restored.isFullScreen, isFalse);
    });
  });

  group('resolveWindowBounds', () {
    const laptop = Rect.fromLTWH(0, 0, 1512, 945);
    const external = Rect.fromLTWH(1512, -300, 2560, 1440);

    test('a frame on a connected display restores as saved', () {
      const saved = Rect.fromLTWH(100, 100, 1200, 800);
      expect(resolveWindowBounds(saved, [laptop, external]), saved);
    });

    test('a frame on the secondary display restores there', () {
      const saved = Rect.fromLTWH(1800, -100, 1600, 1200);
      expect(resolveWindowBounds(saved, [laptop, external]), saved);
    });

    test('a frame on a disconnected monitor falls back to the default', () {
      const saved = Rect.fromLTWH(1800, -100, 1600, 1200);
      expect(resolveWindowBounds(saved, [laptop]), isNull);
    });

    test('a partially visible frame still restores', () {
      // Hanging off the right edge, but plenty left to grab.
      const saved = Rect.fromLTWH(1300, 200, 1000, 700);
      expect(resolveWindowBounds(saved, [laptop]), saved);
    });

    test('a sliver of overlap is not enough to restore', () {
      // Only 40x945 points remain on-screen: too thin to grab the title bar.
      const saved = Rect.fromLTWH(1472, 0, 1000, 700);
      expect(resolveWindowBounds(saved, [laptop]), isNull);
    });

    test('a frame hanging down from above every display is not restorable', () {
      // A 100pt-tall band of the window is visible, but the title bar is
      // above the screen — nothing to drag.
      const saved = Rect.fromLTWH(200, -600, 800, 700);
      expect(resolveWindowBounds(saved, [laptop]), isNull);
    });

    test('a frame starting at the display top edge restores', () {
      const saved = Rect.fromLTWH(200, 0, 800, 700);
      expect(resolveWindowBounds(saved, [laptop]), saved);
    });

    test('degenerate or non-finite frames fall back to the default', () {
      expect(resolveWindowBounds(null, [laptop]), isNull);
      expect(
        resolveWindowBounds(const Rect.fromLTWH(0, 0, 50, 900), [laptop]),
        isNull,
      );
      expect(
        resolveWindowBounds(const Rect.fromLTWH(0, 0, 900, 50), [laptop]),
        isNull,
      );
      expect(
        resolveWindowBounds(
          Rect.fromLTWH(double.nan, 0, 800, 600),
          [laptop],
        ),
        isNull,
      );
      expect(
        resolveWindowBounds(
          Rect.fromLTWH(0, 0, double.infinity, 600),
          [laptop],
        ),
        isNull,
      );
    });

    test('no connected displays means no restore', () {
      expect(
        resolveWindowBounds(const Rect.fromLTWH(0, 0, 800, 600), const []),
        isNull,
      );
    });
  });

  group('WindowStateStore', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('window_state_test');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });

    File storeFile() => File('${dir.path}/window_state.json');

    test('a missing file loads as nothing saved', () async {
      expect(await WindowStateStore(storeFile()).load(), isNull);
    });

    test('saves and reloads a snapshot', () async {
      final store = WindowStateStore(storeFile());
      await store.save(
        const WindowStateSnapshot(
          bounds: Rect.fromLTWH(10, 20, 1000, 700),
          isFullScreen: true,
        ),
      );
      final restored = await WindowStateStore(storeFile()).load();
      expect(restored!.bounds, const Rect.fromLTWH(10, 20, 1000, 700));
      expect(restored.isFullScreen, isTrue);
      expect(restored.isMaximized, isFalse);
    });

    test('an unparseable file loads as nothing saved', () async {
      await storeFile().writeAsString('{not json');
      expect(await WindowStateStore(storeFile()).load(), isNull);
    });

    test('queued saves land last-writer-wins', () async {
      final store = WindowStateStore(storeFile());
      final first = store.save(
        const WindowStateSnapshot(bounds: Rect.fromLTWH(0, 0, 800, 600)),
      );
      final second = store.save(
        const WindowStateSnapshot(bounds: Rect.fromLTWH(5, 5, 900, 700)),
      );
      await Future.wait([first, second]);
      final restored = await WindowStateStore(storeFile()).load();
      expect(restored!.bounds, const Rect.fromLTWH(5, 5, 900, 700));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_settings.dart';

void main() {
  test('checkForUpdates defaults on and round-trips through JSON', () {
    expect(AppSettings().checkForUpdates, isTrue);

    final off = AppSettings(checkForUpdates: false);
    final restored = AppSettings.fromJson(off.toJson());
    expect(restored.checkForUpdates, isFalse);

    final on = AppSettings(checkForUpdates: true);
    expect(AppSettings.fromJson(on.toJson()).checkForUpdates, isTrue);
  });

  test('missing checkForUpdates in stored JSON defaults to on', () {
    final json = AppSettings().toJson()..remove('checkForUpdates');
    expect(AppSettings.fromJson(json).checkForUpdates, isTrue);
  });
}

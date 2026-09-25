import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../app_state.dart';
import '../ui/terminal_appearance.dart';
import 'app_settings.dart';
import 'external_file_opener.dart';
import 'local_settings_backend.dart';
import 'settings_backend.dart';

/// The desktop Settings window: a native window of its own, on a second
/// Flutter engine, whose Dart side runs `runSettingsWindow` rather than the
/// app.
///
/// Created the first time Settings is opened and kept for the rest of the
/// app's life: closing it hides it, and opening it again shows it. Tearing a
/// second engine down is what the runners avoid — on Linux, Flutter 3.47's
/// embedder terminates the EGL display every engine in the process shares
/// when one of them is disposed, and the app's window then dies with an X
/// error. Kept, the window also reopens at once. What a hidden window must
/// not keep is its screen: the window's Dart side unmounts it on [_Link.hidden]
/// — dropping anything typed into the key fields — and mounts a fresh one,
/// loaded from the settings as they are then, on [_Link.show].
///
/// Two channels connect it to the app, both in the runners
/// (`macos/Runner/SettingsWindow.swift`, `linux/runner/settings_window.cc`,
/// `windows/runner/settings_window.cpp`):
///
/// - [settingsWindowControlChannel], on the app's engine only: Dart asks the
///   runner to open the window (or bring it forward), and the runner reports
///   `closed` when the user closes — hides — it.
/// - [settingsWindowLinkChannel], on both engines: the runner forwards every
///   message one engine sends on it to the other, byte for byte, and the
///   reply back. That is the only way two engines can talk — they share
///   nothing else — so it carries the whole of [SettingsBackend].
///
/// Every payload on the link is a JSON string, in both directions, so each
/// side decodes exactly what the other encoded rather than whatever shape the
/// standard codec rebuilds maps into.
const MethodChannel settingsWindowControlChannel = MethodChannel(
  'seance/settings_window',
);

/// See [settingsWindowControlChannel].
const MethodChannel settingsWindowLinkChannel = MethodChannel(
  'seance/settings_link',
);

/// The argument the runners start the settings window's engine with.
const String settingsWindowArgument = '--seance-settings-window';

/// The link's methods. Named once, here, because each is spelled on both
/// sides of an isolate boundary where a typo is a silent `null`.
abstract final class _Link {
  // Window → app.
  static const hello = 'hello';
  static const setCheckForUpdates = 'setCheckForUpdates';
  static const setKeepSessionsAlive = 'setKeepSessionsAlive';
  static const setCommandSuggestions = 'setCommandSuggestions';
  static const setTerminalAppearance = 'setTerminalAppearance';
  static const setEditorRegistry = 'setEditorRegistry';
  static const pickEditor = 'pickEditor';
  static const fetchModels = 'fetchModels';
  static const saveAssistant = 'saveAssistant';
  static const setSyncPrefs = 'setSyncPrefs';
  static const enrollSync = 'enrollSync';
  static const syncNow = 'syncNow';
  static const requestAppExit = 'requestAppExit';

  // App → window.
  static const snapshot = 'snapshot';
  static const selectTab = 'selectTab';
  static const hidden = 'hidden';
  static const show = 'show';
}

/// What the window renders from: the settings and the two live values the
/// screen watches.
Map<String, dynamic> _snapshotOf(SettingsBackend backend) => {
  'settings': backend.settings.toJson(),
  'llmConfigVersion': backend.llmConfigVersion,
  'syncStatus': backend.syncStatus.toJson(),
};

/// The app's side of the settings window: opens it, answers what it asks
/// through a [LocalSettingsBackend], and sends it a fresh snapshot whenever
/// the app's state changes while it is open.
class SettingsWindowHost {
  SettingsWindowHost(
    this._state, {
    this._control = settingsWindowControlChannel,
    this._link = settingsWindowLinkChannel,
    @visibleForTesting Future<AppExitResponse> Function()? requestAppExit,
  }) : _backend = LocalSettingsBackend(_state),
       _requestAppExit =
           requestAppExit ?? WidgetsBinding.instance.handleRequestAppExit {
    _control.setMethodCallHandler(_handleControl);
    _link.setMethodCallHandler(_handleLink);
    _state.addListener(_scheduleSnapshot);
  }

  final AppState _state;
  final LocalSettingsBackend _backend;
  final MethodChannel _control;
  final MethodChannel _link;

  /// The app's answer to "may the application quit?": its own observers'.
  final Future<AppExitResponse> Function() _requestAppExit;

  /// Whether the window's engine has said hello. It is never torn down, so
  /// this stays true once set, unless the link stops answering.
  bool _connected = false;

  /// Whether the window is showing, rather than closed and hidden.
  bool _visible = false;

  /// The tab the next window opens on, or the open one switches to.
  SettingsTab _tab = SettingsTab.general;

  /// The last snapshot sent, encoded, so a state change that moves nothing
  /// the window shows costs a comparison rather than a message.
  String? _lastSnapshot;
  bool _snapshotScheduled = false;

  @visibleForTesting
  bool get connected => _connected;

  @visibleForTesting
  bool get visible => _visible;

  /// Open the window on [tab], or bring an open one forward and switch it
  /// there. False when the runner has no settings window — a build from
  /// before it existed — so the caller can show the Settings route instead.
  Future<bool> open(SettingsTab tab) async {
    _tab = tab;
    if (_connected) {
      try {
        if (_visible) {
          await _link.invokeMethod<void>(_Link.selectTab, jsonEncode(tab.name));
        } else {
          // A fresh screen, from the settings as they are now, before the
          // window reappears: nothing was sent while it was hidden.
          final snapshot = _snapshotOf(_backend);
          _lastSnapshot = jsonEncode(snapshot);
          await _link.invokeMethod<void>(
            _Link.show,
            jsonEncode({'snapshot': snapshot, 'tab': tab.name}),
          );
        }
      } on MissingPluginException {
        // The engine went away after all; a new one says hello, and opens
        // on `_tab`.
        _connected = false;
      }
    }
    try {
      await _control.invokeMethod<void>('open');
    } on MissingPluginException {
      return false;
    }
    // A first window becomes visible when it says hello, which may already
    // have happened; one being shown again, here.
    if (_connected) _visible = true;
    return true;
  }

  void dispose() {
    _state.removeListener(_scheduleSnapshot);
    _control.setMethodCallHandler(null);
    _link.setMethodCallHandler(null);
  }

  Future<Object?> _handleControl(MethodCall call) async {
    if (call.method == 'closed') {
      _visible = false;
      _lastSnapshot = null;
      if (_connected) {
        try {
          await _link.invokeMethod<void>(_Link.hidden);
        } on MissingPluginException {
          _connected = false;
        }
      }
    }
    return null;
  }

  /// Coalesce a burst of state changes into one snapshot, sent after the
  /// current event: the app notifies for far more than the window shows,
  /// and a hidden window shows nothing.
  void _scheduleSnapshot() {
    if (!_connected || !_visible || _snapshotScheduled) return;
    _snapshotScheduled = true;
    scheduleMicrotask(() {
      _snapshotScheduled = false;
      unawaited(_sendSnapshot());
    });
  }

  Future<void> _sendSnapshot() async {
    if (!_connected || !_visible) return;
    final encoded = jsonEncode(_snapshotOf(_backend));
    if (encoded == _lastSnapshot) return;
    _lastSnapshot = encoded;
    try {
      await _link.invokeMethod<void>(_Link.snapshot, encoded);
    } on MissingPluginException {
      _connected = false;
      _lastSnapshot = null;
    }
  }

  Future<Object?> _handleLink(MethodCall call) async {
    final Object? argument = call.arguments is String
        ? jsonDecode(call.arguments as String)
        : null;
    try {
      final result = await _dispatch(call.method, argument);
      return result == null ? null : jsonEncode(result);
    } on MissingPluginException {
      rethrow;
    } catch (e) {
      // The window shows the message the error printed here, which is what
      // the Settings route shows for the same failure.
      throw PlatformException(code: 'settings-failed', message: '$e');
    }
  }

  Future<Object?> _dispatch(String method, Object? argument) async {
    Map<String, dynamic> map() => (argument! as Map).cast<String, dynamic>();
    switch (method) {
      case _Link.hello:
        _connected = true;
        _visible = true;
        final snapshot = _snapshotOf(_backend);
        _lastSnapshot = jsonEncode(snapshot);
        return {'snapshot': snapshot, 'tab': _tab.name};
      case _Link.setCheckForUpdates:
        await _backend.setCheckForUpdates(argument! as bool);
      case _Link.setKeepSessionsAlive:
        await _backend.setKeepSessionsAlive(argument! as bool);
      case _Link.setCommandSuggestions:
        await _backend.setCommandSuggestions(argument! as bool);
      case _Link.setTerminalAppearance:
        final json = map();
        await _backend.setTerminalAppearance(
          fontSize: (json['fontSize'] as num).toDouble(),
          fontFamily: json['fontFamily'] as String,
          palette: TerminalPalette.values.byName(json['palette'] as String),
        );
      case _Link.setEditorRegistry:
        await _backend.setEditorRegistry(EditorRegistry.fromJson(argument));
      case _Link.pickEditor:
        return (await _backend.pickEditor())?.toJson();
      case _Link.fetchModels:
        return await _backend.fetchModels(ModelQuery.fromJson(map()));
      case _Link.saveAssistant:
        return (await _backend.saveAssistant(
          AssistantDraft.fromJson(map()),
        )).toJson();
      case _Link.setSyncPrefs:
        final json = map();
        return (await _backend.setSyncPrefs(
          autoSync: json['autoSync'] as bool,
          syncSecrets: json['syncSecrets'] as bool,
          syncAssistant: json['syncAssistant'] as bool,
        )).toJson();
      case _Link.enrollSync:
        await _backend.enrollSync(SyncEnrollment.fromJson(map()));
      case _Link.syncNow:
        return (await _backend.syncNow()).toJson();
      case _Link.requestAppExit:
        return (await _requestAppExit()).name;
      default:
        throw MissingPluginException('No settings method $method');
    }
    return null;
  }
}

/// What the settings window shows: nothing while it is hidden, or a Settings
/// screen opened on [tab]. [generation] changes every time the window is
/// shown, so each showing is a fresh screen rather than the last one's
/// fields and half-typed keys.
@immutable
class SettingsWindowPage {
  const SettingsWindowPage({required this.tab, required this.generation});

  final SettingsTab tab;
  final int generation;
}

/// The settings window's side: a [SettingsBackend] whose every call runs in
/// the app's isolate, through [SettingsWindowHost].
///
/// [settings] is a copy, replaced by each snapshot the host sends; the screen
/// loads its fields from it once and otherwise only watches the sync status
/// and the configuration version, as it does in the route.
class RemoteSettingsBackend extends ChangeNotifier implements SettingsBackend {
  RemoteSettingsBackend._(this._link);

  final MethodChannel _link;
  final StreamController<SettingsTab> _tabRequests =
      StreamController<SettingsTab>.broadcast();

  late AppSettings _settings;
  late int _llmConfigVersion;
  late SyncStatus _syncStatus;
  int _generation = 1;

  /// What the window shows; see [SettingsWindowPage].
  late final ValueNotifier<SettingsWindowPage?> page;

  /// Tabs the app asks a showing window to switch to (Settings chosen again
  /// from a menu, or "Sync off" pressed while the window is behind).
  Stream<SettingsTab> get tabRequests => _tabRequests.stream;

  /// Say hello to the app and take its first snapshot. Throws a
  /// [SettingsBackendException] when there is no app to answer — the window
  /// was started by hand rather than by the app.
  static Future<RemoteSettingsBackend> connect({
    MethodChannel link = settingsWindowLinkChannel,
  }) async {
    final backend = RemoteSettingsBackend._(link);
    link.setMethodCallHandler(backend._handle);
    final hello = (await backend._call(_Link.hello))! as Map;
    backend._apply((hello['snapshot'] as Map).cast<String, dynamic>());
    backend.page = ValueNotifier(
      SettingsWindowPage(
        tab: SettingsTab.values.byName(hello['tab'] as String),
        generation: 0,
      ),
    );
    return backend;
  }

  @override
  AppSettings get settings => _settings;

  @override
  int get llmConfigVersion => _llmConfigVersion;

  @override
  SyncStatus get syncStatus => _syncStatus;

  void _apply(Map<String, dynamic> snapshot) {
    _settings = AppSettings.fromJson(
      (snapshot['settings'] as Map).cast<String, dynamic>(),
    );
    _llmConfigVersion = snapshot['llmConfigVersion'] as int;
    _syncStatus = SyncStatus.fromJson(
      (snapshot['syncStatus'] as Map).cast<String, dynamic>(),
    );
  }

  Future<Object?> _handle(MethodCall call) async {
    final Object? argument = call.arguments is String
        ? jsonDecode(call.arguments as String)
        : null;
    switch (call.method) {
      case _Link.snapshot:
        _apply((argument! as Map).cast<String, dynamic>());
        notifyListeners();
      case _Link.selectTab:
        _tabRequests.add(SettingsTab.values.byName(argument! as String));
      case _Link.hidden:
        page.value = null;
      case _Link.show:
        final json = (argument! as Map).cast<String, dynamic>();
        _apply((json['snapshot'] as Map).cast<String, dynamic>());
        notifyListeners();
        page.value = SettingsWindowPage(
          tab: SettingsTab.values.byName(json['tab'] as String),
          generation: _generation++,
        );
      default:
        throw MissingPluginException(
          'No settings window method ${call.method}',
        );
    }
    return null;
  }

  Future<Object?> _call(String method, [Object? argument]) async {
    try {
      final reply = await _link.invokeMethod<String>(
        method,
        argument == null ? null : jsonEncode(argument),
      );
      return reply == null ? null : jsonDecode(reply);
    } on PlatformException catch (e) {
      throw SettingsBackendException(e.message ?? e.code);
    } on MissingPluginException {
      throw const SettingsBackendException(
        'Séance is not responding. Close this window and open Settings again.',
      );
    }
  }

  Map<String, dynamic> _map(Object? value) =>
      (value! as Map).cast<String, dynamic>();

  @override
  Future<void> setCheckForUpdates(bool enabled) =>
      _call(_Link.setCheckForUpdates, enabled);

  @override
  Future<void> setKeepSessionsAlive(bool enabled) =>
      _call(_Link.setKeepSessionsAlive, enabled);

  @override
  Future<void> setCommandSuggestions(bool enabled) =>
      _call(_Link.setCommandSuggestions, enabled);

  @override
  Future<void> setTerminalAppearance({
    required double fontSize,
    required String fontFamily,
    required TerminalPalette palette,
  }) => _call(_Link.setTerminalAppearance, {
    'fontSize': fontSize,
    'fontFamily': fontFamily,
    'palette': palette.name,
  });

  @override
  Future<void> setEditorRegistry(EditorRegistry registry) =>
      _call(_Link.setEditorRegistry, registry.toJson());

  @override
  Future<ExternalEditorDefinition?> pickEditor() async {
    final json = await _call(_Link.pickEditor);
    return json == null ? null : ExternalEditorDefinition.fromJson(_map(json));
  }

  @override
  Future<List<String>> fetchModels(ModelQuery query) async =>
      ((await _call(_Link.fetchModels, query.toJson()))! as List)
          .cast<String>();

  @override
  Future<AssistantSaveResult> saveAssistant(AssistantDraft draft) async =>
      AssistantSaveResult.fromJson(
        _map(await _call(_Link.saveAssistant, draft.toJson())),
      );

  @override
  Future<SyncPrefsResult> setSyncPrefs({
    required bool autoSync,
    required bool syncSecrets,
    required bool syncAssistant,
  }) async => SyncPrefsResult.fromJson(
    _map(
      await _call(_Link.setSyncPrefs, {
        'autoSync': autoSync,
        'syncSecrets': syncSecrets,
        'syncAssistant': syncAssistant,
      }),
    ),
  );

  @override
  Future<void> enrollSync(SyncEnrollment enrollment) =>
      _call(_Link.enrollSync, enrollment.toJson());

  @override
  Future<SyncCounts> syncNow() async =>
      SyncCounts.fromJson(_map(await _call(_Link.syncNow)));

  /// Whether the application may quit, as the app's isolate decides it.
  ///
  /// The window's engine can be the one asked. On macOS every engine makes
  /// itself the app delegate's termination handler when it starts, so once
  /// this window exists ⌘Q — and the app's own quit, which goes through
  /// `NSApp.terminate` — asks this isolate, whose framework answers "exit"
  /// for want of any observer; the app's exit handling would never run.
  /// Forwarded, the app's observers decide, as they did before the window.
  /// With no app left to ask, quitting is not held up.
  Future<AppExitResponse> requestAppExit() async {
    try {
      final name = await _call(_Link.requestAppExit);
      return AppExitResponse.values.byName(name! as String);
    } on SettingsBackendException {
      return AppExitResponse.exit;
    }
  }

  @override
  void dispose() {
    _link.setMethodCallHandler(null);
    unawaited(_tabRequests.close());
    page.dispose();
    super.dispose();
  }
}

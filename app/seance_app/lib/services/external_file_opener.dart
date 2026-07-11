import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:seance_core/seance_core.dart';

enum EditorHostPlatform { macos, linux, windows }

class ExternalEditorDefinition {
  final String id;
  final String displayName;
  final EditorHostPlatform platform;

  /// Bundle identifier on macOS; absolute executable path elsewhere.
  final String launchTarget;
  final List<String> acceptedExtensions;

  const ExternalEditorDefinition({
    required this.id,
    required this.displayName,
    required this.platform,
    required this.launchTarget,
    this.acceptedExtensions = const [],
  });

  factory ExternalEditorDefinition.fromJson(Map<String, dynamic> json) {
    final platformName = json['platform'];
    final platform = EditorHostPlatform.values.where(
      (value) => value.name == platformName,
    );
    if (platform.isEmpty) {
      throw const FormatException('Unknown editor platform');
    }
    final parsedPlatform = platform.first;
    return ExternalEditorDefinition(
      id: _validatedId(json['id']),
      displayName: validateEditorDisplayName(json['displayName']),
      platform: parsedPlatform,
      launchTarget: _validatedTarget(json['launchTarget'], parsedPlatform),
      acceptedExtensions: normalizeEditorExtensions(
        json['acceptedExtensions'] is List
            ? (json['acceptedExtensions'] as List).whereType<String>()
            : const [],
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'platform': platform.name,
    'launchTarget': launchTarget,
    'acceptedExtensions': acceptedExtensions,
  };

  ExternalEditorDefinition copyWith({
    String? displayName,
    List<String>? acceptedExtensions,
  }) => ExternalEditorDefinition(
    id: id,
    displayName: validateEditorDisplayName(displayName ?? this.displayName),
    platform: platform,
    launchTarget: launchTarget,
    acceptedExtensions: acceptedExtensions ?? this.acceptedExtensions,
  );

  bool acceptsPath(String path) {
    if (acceptedExtensions.isEmpty) return true;
    final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
    return acceptedExtensions.any((extension) => name.endsWith('.$extension'));
  }

  bool get isAvailableOnCurrentPlatform =>
      platform == currentEditorHostPlatform;
}

class EditorRegistry {
  static const systemDefaultId = 'seance.system';
  static const builtInId = 'seance.builtin';
  static const migratedBbeditId = 'macos.com.barebones.bbedit';

  String defaultEditorId;
  final List<ExternalEditorDefinition> editors;

  EditorRegistry({
    this.defaultEditorId = systemDefaultId,
    Iterable<ExternalEditorDefinition> editors = const [],
  }) : editors = List.of(editors) {
    _repairDefault();
  }

  factory EditorRegistry.fromJson(Object? value, {Object? legacyEditor}) {
    if (value is Map) {
      final json = value.cast<Object?, Object?>();
      final editors = <ExternalEditorDefinition>[];
      final ids = <String>{};
      final entries = json['editors'];
      if (entries is List) {
        for (final entry in entries.take(64)) {
          if (entry is! Map) continue;
          try {
            final editor = ExternalEditorDefinition.fromJson(
              entry.cast<String, dynamic>(),
            );
            if (_isReservedEditorId(editor.id)) continue;
            if (ids.add(editor.id)) editors.add(editor);
          } catch (_) {
            // Keep other valid entries when one persisted app is malformed.
          }
        }
      }
      return EditorRegistry(
        defaultEditorId: json['defaultEditorId'] is String
            ? json['defaultEditorId'] as String
            : systemDefaultId,
        editors: editors,
      );
    }
    if (legacyEditor == 'bbedit') {
      return EditorRegistry(
        defaultEditorId: migratedBbeditId,
        editors: const [
          ExternalEditorDefinition(
            id: migratedBbeditId,
            displayName: 'BBEdit',
            platform: EditorHostPlatform.macos,
            launchTarget: 'com.barebones.bbedit',
          ),
        ],
      );
    }
    return EditorRegistry();
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'defaultEditorId': defaultEditorId,
    'editors': editors.map((editor) => editor.toJson()).toList(),
  };

  ExternalEditorDefinition? byId(String id) {
    for (final editor in editors) {
      if (editor.id == id) return editor;
    }
    return null;
  }

  List<ExternalEditorDefinition> compatibleEditors(String path) => [
    for (final editor in editors)
      if (editor.isAvailableOnCurrentPlatform && editor.acceptsPath(path))
        editor,
  ];

  String effectiveDefaultFor(String path) {
    if (defaultEditorId == builtInId) {
      return defaultEditorId;
    }
    // Mobile open/share APIs generally hand another app a copy rather than an
    // in-place editable checkout. Keep remote editing reliable there.
    if (defaultEditorId == systemDefaultId) {
      return currentEditorHostPlatform == null ? builtInId : systemDefaultId;
    }
    final editor = byId(defaultEditorId);
    if (editor == null ||
        !editor.isAvailableOnCurrentPlatform ||
        !editor.acceptsPath(path)) {
      return currentEditorHostPlatform == null ? builtInId : systemDefaultId;
    }
    return editor.id;
  }

  void put(ExternalEditorDefinition editor) {
    _validatedId(editor.id);
    if (_isReservedEditorId(editor.id)) {
      throw const FormatException('Editor id is reserved');
    }
    validateEditorDisplayName(editor.displayName);
    _validatedTarget(editor.launchTarget, editor.platform);
    normalizeEditorExtensions(editor.acceptedExtensions);
    final index = editors.indexWhere((item) => item.id == editor.id);
    if (index < 0) {
      if (editors.length >= 64) {
        throw StateError('At most 64 external editors can be configured.');
      }
      editors.add(editor);
    } else {
      editors[index] = editor;
    }
  }

  void remove(String id) {
    editors.removeWhere((editor) => editor.id == id);
    if (defaultEditorId == id) defaultEditorId = systemDefaultId;
  }

  void _repairDefault() {
    if (defaultEditorId == systemDefaultId || defaultEditorId == builtInId) {
      return;
    }
    if (byId(defaultEditorId) == null) defaultEditorId = systemDefaultId;
  }
}

bool _isReservedEditorId(String id) =>
    id == EditorRegistry.systemDefaultId || id == EditorRegistry.builtInId;

EditorHostPlatform? get currentEditorHostPlatform {
  if (Platform.isMacOS) return EditorHostPlatform.macos;
  if (Platform.isLinux) return EditorHostPlatform.linux;
  if (Platform.isWindows) return EditorHostPlatform.windows;
  return null;
}

List<String> normalizeEditorExtensions(Iterable<String> values) {
  final result = <String>{};
  for (var value in values) {
    value = value.trim().toLowerCase();
    while (value.startsWith('.')) {
      value = value.substring(1);
    }
    if (value.startsWith('*')) value = value.substring(1);
    while (value.startsWith('.')) {
      value = value.substring(1);
    }
    if (value.isEmpty) continue;
    if (value.length > 32 || RegExp(r'[/\\*?\x00-\x1f\x7f]').hasMatch(value)) {
      throw FormatException('Invalid file extension: $value');
    }
    result.add(value);
    if (result.length > 64) {
      throw const FormatException('At most 64 extensions can be configured.');
    }
  }
  return result.toList()..sort();
}

/// Opens managed checkouts without ever constructing a shell command.
class ExternalFileOpener {
  static const channel = MethodChannel('seance/files');

  const ExternalFileOpener();

  Future<void> openSystemDefault(String path) async {
    final result = await OpenFile.open(path);
    if (result.type != ResultType.done) throw StateError(result.message);
  }

  Future<void> openWith(String path, ExternalEditorDefinition editor) async {
    if (!editor.isAvailableOnCurrentPlatform) {
      throw UnsupportedError(
        '${editor.displayName} is configured for another platform.',
      );
    }
    if (editor.platform == EditorHostPlatform.macos) {
      await channel.invokeMethod<void>('openWithApplication', {
        'path': path,
        'bundleIdentifier': editor.launchTarget,
      });
      return;
    }
    final executable = File(editor.launchTarget);
    final type = await FileSystemEntity.type(editor.launchTarget);
    if (!executable.isAbsolute || type != FileSystemEntityType.file) {
      throw StateError(
        '${editor.displayName} is no longer installed at ${editor.launchTarget}.',
      );
    }
    if (editor.platform == EditorHostPlatform.linux &&
        ((await executable.stat()).mode & 0x49) == 0) {
      throw StateError('${editor.displayName} is not executable.');
    }
    await Process.start(
      editor.launchTarget,
      [path],
      runInShell: false,
      mode: ProcessStartMode.detached,
    );
  }

  Future<ExternalEditorDefinition?> pickEditor() async {
    final platform = currentEditorHostPlatform;
    if (platform == null) return null;
    if (platform == EditorHostPlatform.macos) {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'pickApplication',
      );
      if (result == null) return null;
      final bundleIdentifier = result['bundleIdentifier'] as String?;
      if (bundleIdentifier == null || bundleIdentifier.isEmpty) {
        throw StateError('The selected application has no bundle identifier.');
      }
      return ExternalEditorDefinition(
        id: uuidV4(),
        displayName: validateEditorDisplayName(result['displayName']),
        platform: platform,
        launchTarget: bundleIdentifier,
      );
    }
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Choose an editor application',
      allowMultiple: false,
      type: platform == EditorHostPlatform.windows
          ? FileType.custom
          : FileType.any,
      allowedExtensions: platform == EditorHostPlatform.windows
          ? const ['exe']
          : null,
      lockParentWindow: platform == EditorHostPlatform.windows,
    );
    final path = result?.files.single.path;
    if (path == null) return null;
    final file = File(path);
    final type = await FileSystemEntity.type(path);
    if (!file.isAbsolute || type != FileSystemEntityType.file) {
      throw StateError('Choose a regular executable file.');
    }
    if (platform == EditorHostPlatform.windows &&
        !path.toLowerCase().endsWith('.exe')) {
      throw StateError('Windows editors must be .exe applications.');
    }
    if (platform == EditorHostPlatform.linux &&
        ((await file.stat()).mode & 0x49) == 0) {
      throw StateError('The selected file is not executable.');
    }
    final name = path.split(Platform.pathSeparator).last;
    return ExternalEditorDefinition(
      id: uuidV4(),
      displayName: validateEditorDisplayName(
        platform == EditorHostPlatform.windows &&
                name.toLowerCase().endsWith('.exe')
            ? name.substring(0, name.length - 4)
            : name,
      ),
      platform: platform,
      launchTarget: path,
    );
  }
}

String _validatedId(Object? value) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(value)) {
    throw const FormatException('Invalid editor id');
  }
  return value;
}

String validateEditorDisplayName(Object? value) {
  if (value is! String) throw const FormatException('Invalid editor name');
  final name = value.trim();
  if (name.isEmpty ||
      name.length > 100 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
    throw const FormatException('Invalid editor name');
  }
  return name;
}

String _validatedTarget(Object? value, EditorHostPlatform platform) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 4096 ||
      value.contains('\u0000')) {
    throw const FormatException('Invalid editor target');
  }
  if (platform != EditorHostPlatform.macos && !File(value).isAbsolute) {
    throw const FormatException('Editor executable paths must be absolute');
  }
  if (platform == EditorHostPlatform.windows &&
      !value.toLowerCase().endsWith('.exe')) {
    throw const FormatException('Windows editors must be .exe applications');
  }
  return value;
}

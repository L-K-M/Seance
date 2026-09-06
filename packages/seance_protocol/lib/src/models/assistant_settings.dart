/// The assistant's configuration, as one synced record.
///
/// Everything here describes *which assistant*, not *which machine*: the
/// provider and model, where to reach it, which web-search backends are on,
/// and whether outbound context is redacted. That is the line the rest of
/// `AppSettings` draws too — terminal font size, editor registry and
/// security-scoped bookmarks stay on the device that has the screen, the apps
/// and the OS grants they refer to.
///
/// It is a singleton: one record under a fixed id, so two devices that each
/// configure an assistant converge onto one row rather than two. That also
/// means conflicts are resolved whole-record by [Lww], like a `ServerConfig`
/// and unlike a field-level merge — configuring a model on one device while
/// changing the search backend on another loses one of the two edits. The
/// alternative (per-field timestamps merged on apply) would be a second
/// conflict rule the *server* does not share, since it runs `Lww.resolve` too.
class AssistantSettings {
  /// The provider's `LlmProviderKind` **name**, not a parsed value.
  ///
  /// A closed set stored as a name, for the reason `ServerConfig.color` is:
  /// a device on a newer build may name a provider this one has never heard
  /// of, and the reader decides what to do with that (keep what it has) rather
  /// than being handed a wrong value. The enum itself lives in `seance_core`,
  /// which this package deliberately does not depend on.
  final String providerKind;

  final String baseUrl;
  final String model;

  /// Keystore entry *name* for the provider key, matching
  /// `AppSettings.llmApiKeyRef`. Empty for a keyless local endpoint.
  final String llmApiKeyRef;

  final String? searxngUrl;
  final String? braveApiKeyRef;
  final String? zaiApiKeyRef;

  /// Whether the assistant redacts secrets from outbound context.
  ///
  /// Synced along with the rest even though the risky direction is "off": this
  /// is one person's own devices behind end-to-end encryption, and a setting
  /// that silently means something different on each of them is its own kind
  /// of surprise. Nothing here can turn it off without the user turning it off.
  final bool redactSecrets;

  /// API keys by keystore entry name, empty when this configuration
  /// references none.
  ///
  /// Empty is a real state rather than an opt-out: a local gateway that wants
  /// no key at all leaves every reference blank. There is no switch for
  /// syncing the configuration *without* its keys — that would publish a
  /// setup which looks configured everywhere and answers nowhere — so
  /// assistant sync is all-or-nothing by design.
  ///
  /// Absent from this map means "look locally", never "forget the entry you
  /// have": a record that cleared local keys would break the assistant on
  /// every device that adopted it, which is why the apply path only ever
  /// writes the keys a record carries.
  ///
  /// Keys travel *inside* the record, which is sealed with the vault key
  /// before it leaves — the same protection a synced password gets. The map is
  /// built from the entry names this object itself references and never by
  /// enumerating the keystore: the sync token and the vault key live in that
  /// same keystore, and neither may ever appear here.
  final Map<String, String> apiKeys;

  /// When the user last changed any of this. Deliberately not "now at collect
  /// time": the coordinator re-collects every round, so a moving timestamp
  /// would make each five-minute sync a fresh winning write and two devices
  /// would trade the record back and forth forever.
  ///
  /// Device wall-clock time, like every other record's, so a device whose
  /// clock runs fast wins concurrent edits until the others catch up. The app
  /// clamps its own stamps upward past whatever record it already holds, which
  /// covers the case that actually bites — an edit losing to the record the
  /// same device just adopted. Genuine skew between two devices' edits is what
  /// a hybrid logical clock or a server-assigned sequence would answer, and
  /// that is a change to how every record resolves, not this one.
  final int updatedAt;

  const AssistantSettings({
    required this.providerKind,
    required this.baseUrl,
    required this.model,
    this.llmApiKeyRef = '',
    this.searxngUrl,
    this.braveApiKeyRef,
    this.zaiApiKeyRef,
    this.redactSecrets = true,
    this.apiKeys = const {},
    required this.updatedAt,
  });

  /// The one id this record ever has. Constant rather than a uuid — that is
  /// what makes it a singleton — and prefixed, because `applyToStores` reads a
  /// tombstone with a bare id as a server deletion.
  static const String recordId = 'assistant:settings';

  AssistantSettings copyWith({
    String? providerKind,
    String? baseUrl,
    String? model,
    String? llmApiKeyRef,
    String? searxngUrl,
    bool clearSearxngUrl = false,
    String? braveApiKeyRef,
    bool clearBraveApiKeyRef = false,
    String? zaiApiKeyRef,
    bool clearZaiApiKeyRef = false,
    bool? redactSecrets,
    Map<String, String>? apiKeys,
    int? updatedAt,
  }) =>
      AssistantSettings(
        providerKind: providerKind ?? this.providerKind,
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        llmApiKeyRef: llmApiKeyRef ?? this.llmApiKeyRef,
        searxngUrl: clearSearxngUrl ? null : (searxngUrl ?? this.searxngUrl),
        braveApiKeyRef: clearBraveApiKeyRef
            ? null
            : (braveApiKeyRef ?? this.braveApiKeyRef),
        zaiApiKeyRef:
            clearZaiApiKeyRef ? null : (zaiApiKeyRef ?? this.zaiApiKeyRef),
        redactSecrets: redactSecrets ?? this.redactSecrets,
        apiKeys: apiKeys ?? this.apiKeys,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'providerKind': providerKind,
        'baseUrl': baseUrl,
        'model': model,
        // Blank reads as empty (see [fromJson]); written the same way so the
        // record round-trips.
        'llmApiKeyRef': _isSet(llmApiKeyRef) ? llmApiKeyRef : '',
        // Blank is the same as absent on the way *in* (see [_blankToNull]),
        // so writing one out would be a field the writer calls set and every
        // reader — including this class re-reading its own record — calls
        // unset. A cleared text box is the ordinary way to produce one.
        if (_isSet(searxngUrl)) 'searxngUrl': searxngUrl,
        if (_isSet(braveApiKeyRef)) 'braveApiKeyRef': braveApiKeyRef,
        if (_isSet(zaiApiKeyRef)) 'zaiApiKeyRef': zaiApiKeyRef,
        'redactSecrets': redactSecrets,
        // Omitted rather than written empty, so a record from a device that
        // does not sync keys is byte-identical to one that has none.
        // Through the same filter [fromJson] applies, so a degenerate entry
        // a caller built by hand is not written as set and read back as gone.
        if (_stringMap(apiKeys).isNotEmpty) 'apiKeys': _stringMap(apiKeys),
        'updatedAt': updatedAt,
      };

  factory AssistantSettings.fromJson(Map<String, dynamic> json) =>
      AssistantSettings(
        providerKind: json['providerKind'] as String? ?? '',
        baseUrl: json['baseUrl'] as String? ?? '',
        model: json['model'] as String? ?? '',
        llmApiKeyRef: _blankToNull(json['llmApiKeyRef']) ?? '',
        searxngUrl: _blankToNull(json['searxngUrl']),
        braveApiKeyRef: _blankToNull(json['braveApiKeyRef']),
        zaiApiKeyRef: _blankToNull(json['zaiApiKeyRef']),
        // Absent means "an older writer that had no such field"; the safe
        // reading of that is the default the app ships with, which is on.
        redactSecrets: json['redactSecrets'] as bool? ?? true,
        // Unmodifiable so a decoded record cannot have its key material
        // rewritten through the field it exposes. The const constructor still
        // aliases a caller-supplied map; callers treat it as read-only.
        apiKeys: Map.unmodifiable(_stringMap(json['apiKeys'])),
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() =>
      'AssistantSettings(providerKind: $providerKind, model: $model, '
      'apiKeys: <${apiKeys.length} redacted>)';
}

/// A blank string reads as "not set", so a cleared field on one device does
/// not arrive on another as an endpoint made of nothing. Whitespace counts as
/// blank: a field cleared down to a stray space is a cleared field, and
/// keeping it would hand the request layer a URL made of nothing at all.
String? _blankToNull(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  return value;
}

/// The writer's half of [_blankToNull] — the two have to agree, or a record
/// fails to round-trip through its own encoder.
bool _isSet(String? value) => value != null && value.trim().isNotEmpty;

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries)
      // A blank name addresses no keystore entry, and a blank value would
      // overwrite a working key with nothing on every device that adopted
      // the record — the one outcome "an absent key means look locally"
      // exists to prevent, arriving as a present one instead.
      if (entry.key is String &&
          entry.value is String &&
          (entry.key as String).isNotEmpty &&
          (entry.value as String).isNotEmpty)
        entry.key as String: entry.value as String,
  };
}

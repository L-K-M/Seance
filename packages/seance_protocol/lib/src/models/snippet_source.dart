/// A remote JSON file of read-only snippets the user subscribes to, such as a
/// raw file URL in a private git repository.
///
/// Non-secret and synced across devices like [Snippet], so a source added on
/// one device appears on the others. The access token is not part of it: it
/// lives in the encrypted vault as a [Secret] named by [tokenRef], because this
/// object is persisted in plaintext and, like every record, crosses the sync
/// boundary on its own terms. The token reaches other devices only through the
/// opt-in credential sync, as a `secret:` record of its own.
///
/// What the source *serves* is never stored here or synced: each device
/// fetches the file itself and keeps its own cached copy.
class SnippetSource {
  final String id;

  /// What the Snippets tab groups the source's snippets under.
  final String name;

  /// Where the snippets file is fetched from. HTTPS, except for loopback
  /// addresses, which is enforced where the URL is entered and again where it
  /// is fetched, since a synced record can carry anything.
  final String url;

  /// Id of the vault entry holding the access token, or null for a source
  /// fetched without one.
  final String? tokenRef;

  final int createdAt;
  final int updatedAt;

  const SnippetSource({
    required this.id,
    required this.name,
    required this.url,
    this.tokenRef,
    required this.createdAt,
    required this.updatedAt,
  });

  /// This source with the given fields replaced. [tokenRef] cannot be cleared
  /// through this (null keeps it); pass [clearTokenRef] for that.
  SnippetSource copyWith({
    String? name,
    String? url,
    String? tokenRef,
    bool clearTokenRef = false,
    int? updatedAt,
  }) =>
      SnippetSource(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        tokenRef: clearTokenRef ? null : tokenRef ?? this.tokenRef,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        if (tokenRef != null) 'tokenRef': tokenRef,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory SnippetSource.fromJson(Map<String, dynamic> json) => SnippetSource(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        tokenRef: json['tokenRef'] as String?,
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

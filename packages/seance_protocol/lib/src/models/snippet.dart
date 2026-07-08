/// A reusable command template the user can insert into the prompt. The [body]
/// may contain `{{name}}` placeholders that are filled in at insert time.
/// Non-secret and synced across devices like [ServerConfig].
class Snippet {
  final String id;
  final String title;
  final String body;
  final int createdAt;
  final int updatedAt;

  const Snippet({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
  });

  // `{{ name }}` — inner text is trimmed; nested braces aren't supported.
  static final RegExp _placeholder = RegExp(r'\{\{\s*([^{}]+?)\s*\}\}');

  /// The distinct placeholder names, in first-appearance order.
  List<String> get placeholders {
    final seen = <String>{};
    final out = <String>[];
    for (final m in _placeholder.allMatches(body)) {
      final name = m.group(1)!.trim();
      if (name.isNotEmpty && seen.add(name)) out.add(name);
    }
    return out;
  }

  /// Substitute placeholder [values] into the body. Placeholders without a
  /// value are left untouched.
  String fill(Map<String, String> values) =>
      body.replaceAllMapped(_placeholder, (m) {
        final name = m.group(1)!.trim();
        return values[name] ?? m.group(0)!;
      });

  Snippet copyWith({String? title, String? body, int? updatedAt}) => Snippet(
        id: id,
        title: title ?? this.title,
        body: body ?? this.body,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory Snippet.fromJson(Map<String, dynamic> json) => Snippet(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

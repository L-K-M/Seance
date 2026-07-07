import 'dart:convert';

/// Parses a Server-Sent Events byte stream into the JSON objects carried on its
/// `data:` lines. Shared by both providers' streaming paths. Non-JSON data
/// lines (notably OpenAI's terminal `[DONE]`) are skipped.
Stream<Map<String, dynamic>> parseSseJson(Stream<List<int>> bytes) async* {
  final lines = utf8.decoder.bind(bytes).transform(const LineSplitter());
  await for (final line in lines) {
    if (!line.startsWith('data:')) continue;
    final payload = line.substring(5).trim();
    if (payload.isEmpty || payload == '[DONE]') continue;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) yield decoded;
    } on FormatException {
      // Ignore keep-alive comments and malformed partials.
    }
  }
}

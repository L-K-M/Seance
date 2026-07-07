import 'dart:typed_data';

import 'package:crypto/crypto.dart' as classic;

/// Encodes a 32-byte vault key as a human-transcribable recovery code so a user
/// can enrol a second device by typing it in (the Atuin model).
///
/// Uses Crockford Base32 (no I/L/O/U, case-insensitive) plus a 1-symbol
/// checksum, formatted in dash-separated groups of four. A recovery code round
/// trips exactly to the original bytes, and a single mistyped character is
/// detected rather than silently producing a wrong key.
///
/// (BIP39 word lists are the fancier UX and a candidate future swap; a
/// checksummed Base32 code keeps the protocol package free of a 2048-word
/// asset and is just as safe to copy-paste.)
class RecoveryKey {
  static const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// Encode arbitrary bytes (typically the 32-byte master key) to a code.
  static String encode(List<int> bytes) {
    final data = Uint8List.fromList(bytes);
    final symbols = _toBase32(data);
    final checksum = _checksumSymbol(data);
    final all = symbols + checksum;
    return _group(all);
  }

  /// Decode a recovery code back to bytes, tolerating spaces, dashes, and case.
  /// Throws [FormatException] on an unknown character or checksum failure.
  static Uint8List decode(String code) {
    final cleaned = code
        .toUpperCase()
        .replaceAll('-', '')
        .replaceAll(' ', '')
        // Crockford treats these as their canonical digits.
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1');
    if (cleaned.isEmpty) {
      throw const FormatException('Empty recovery code');
    }
    final body = cleaned.substring(0, cleaned.length - 1);
    final checksum = cleaned.substring(cleaned.length - 1);
    final bytes = _fromBase32(body);
    if (_checksumSymbol(bytes) != checksum) {
      throw const FormatException('Recovery code checksum failed');
    }
    return bytes;
  }

  static String _toBase32(Uint8List data) {
    final sb = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in data) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        sb.write(_alphabet[(buffer >> bits) & 0x1f]);
      }
    }
    if (bits > 0) {
      sb.write(_alphabet[(buffer << (5 - bits)) & 0x1f]);
    }
    return sb.toString();
  }

  static Uint8List _fromBase32(String symbols) {
    final out = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final ch in symbols.split('')) {
      final value = _alphabet.indexOf(ch);
      if (value < 0) {
        throw FormatException('Invalid recovery-code character: $ch');
      }
      buffer = (buffer << 5) | value;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xff);
      }
    }
    return Uint8List.fromList(out);
  }

  static String _checksumSymbol(Uint8List data) {
    final digest = classic.sha256.convert(data).bytes;
    return _alphabet[digest.first % 32];
  }

  static String _group(String s) {
    final sb = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && i % 4 == 0) sb.write('-');
      sb.write(s[i]);
    }
    return sb.toString();
  }
}

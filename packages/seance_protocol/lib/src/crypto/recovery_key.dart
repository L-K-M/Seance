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
  static const int _keyLength = 32;

  // A 32-byte key fills 51 Base32 symbols and one bit of the 52nd; the
  // 52nd symbol's remaining four bits must be zero in the canonical form.
  static const int _bodyLength = 52;

  // The grouped form is 67 characters, leaving ample room for extra separators
  // while bounding work before normalization creates intermediate strings.
  static const int _maxInputLength = 256;

  /// Number of trailing checksum symbols. Two Crockford symbols give ~10 bits,
  /// so a single mistyped character is missed only ~1 in 1024 — enough to catch
  /// realistic transcription errors.
  static const int _checksumLength = 2;

  /// Encode a 32-byte master key to a code.
  static String encode(List<int> bytes) {
    if (bytes.length != _keyLength) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'Recovery keys must be exactly $_keyLength bytes',
      );
    }
    final data = Uint8List.fromList(bytes);
    final symbols = _toBase32(data);
    final checksum = _checksum(data);
    return _group(symbols + checksum);
  }

  /// Decode a recovery code back to bytes, tolerating spaces, dashes, and case.
  /// Throws [FormatException] on an unknown character or checksum failure.
  static Uint8List decode(String code) {
    if (code.length > _maxInputLength) {
      throw const FormatException('Recovery code too long');
    }
    final cleaned = code
        .toUpperCase()
        .replaceAll('-', '')
        .replaceAll(' ', '')
        // Crockford treats these as their canonical digits.
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1');
    if (cleaned.length != _bodyLength + _checksumLength) {
      throw const FormatException(
        'Recovery code must contain exactly 54 Base32 symbols after removing '
        'spaces and dashes',
      );
    }
    final body = cleaned.substring(0, _bodyLength);
    final checksum = cleaned.substring(_bodyLength);
    final bytes = _fromBase32(body);

    // The fixed body length currently implies 32 decoded bytes. Keep this
    // defense in depth in case the encoding or length constants change.
    if (bytes.length != _keyLength) {
      throw const FormatException('Recovery code has an invalid key length');
    }
    // Re-encoding also proves the four unused bits in symbol 52 were zero.
    if (_toBase32(bytes) != body) {
      throw const FormatException('Recovery code is not canonical');
    }
    if (_checksum(bytes) != checksum) {
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

  static String _checksum(Uint8List data) {
    final digest = classic.sha256.convert(data).bytes;
    final sb = StringBuffer();
    for (var i = 0; i < _checksumLength; i++) {
      sb.write(_alphabet[digest[i] % 32]);
    }
    return sb.toString();
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

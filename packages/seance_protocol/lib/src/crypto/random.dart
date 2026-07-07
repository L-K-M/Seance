import 'dart:math';
import 'dart:typed_data';

final Random _secure = Random.secure();

/// Cryptographically secure random bytes.
Uint8List secureRandomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _secure.nextInt(256);
  }
  return out;
}

/// An RFC 4122 version-4 (random) UUID, lower-case, hyphenated.
String uuidV4() {
  final b = secureRandomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
  String hex(int start, int end) {
    final sb = StringBuffer();
    for (var i = start; i < end; i++) {
      sb.write(b[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

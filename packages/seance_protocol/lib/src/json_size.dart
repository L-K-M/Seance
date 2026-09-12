/// Exact byte sizes of JSON values, counted instead of encoded.
///
/// A client has to size a push body against the server's limit before it sends
/// it, and the server measures raw body bytes. Encoding each record just to
/// measure it would allocate a second copy of every blob — megabytes during the
/// first sync of a full vault, which is precisely the case batching exists for
/// — so the base64 blob, the expensive part, is counted arithmetically.
///
/// `test/push_size_test.dart` pins every helper here against a real
/// `jsonEncode`, so an arithmetic slip cannot survive a test run.
library;

import 'dart:convert';

/// Bytes a JSON object costs beyond its entries: the two braces plus one comma
/// between neighbouring entries.
int jsonObjectFramingBytes(int entryCount) =>
    2 + (entryCount > 1 ? entryCount - 1 : 0);

/// Bytes a JSON array costs beyond its elements: the two brackets plus one
/// comma between neighbouring elements.
int jsonArrayFramingBytes(int elementCount) =>
    2 + (elementCount > 1 ? elementCount - 1 : 0);

/// Bytes an object entry's `"<key>":` prefix costs.
int jsonKeyBytes(String key) => jsonStringBytes(key) + 1;

/// Bytes a JSON string literal costs, quotes and escapes included.
///
/// This one does encode: it is only ever applied to short keys, ids and device
/// names, and reimplementing the escaping rules (control characters, surrogate
/// pairs) would be the kind of arithmetic that silently disagrees with the
/// encoder on some input nobody tested.
int jsonStringBytes(String value) => utf8.encode(jsonEncode(value)).length;

/// Bytes a JSON integer costs: its decimal text, which is ASCII.
int jsonIntBytes(int value) => value.toString().length;

/// Bytes a JSON boolean costs.
int jsonBoolBytes(bool value) => value ? 4 : 5;

/// Bytes `base64.encode` of [byteCount] bytes costs as a JSON string. Base64
/// is ASCII and needs no escaping, so this is the quotes plus the padded
/// base64 length — no encoding, and no copy of the blob.
int jsonBase64StringBytes(int byteCount) => 2 + ((byteCount + 2) ~/ 3) * 4;

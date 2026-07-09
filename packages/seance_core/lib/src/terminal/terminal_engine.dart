import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

class TerminalSize {
  final int cols;
  final int rows;
  const TerminalSize(this.cols, this.rows);

  @override
  bool operator ==(Object other) =>
      other is TerminalSize && other.cols == cols && other.rows == rows;
  @override
  int get hashCode => Object.hash(cols, rows);
  @override
  String toString() => '${cols}x$rows';
}

/// The seam between Séance and whatever renders the terminal. v1 backs this with
/// a vendored xterm.dart widget in the Flutter app; a future libghostty engine
/// slots in behind the same interface, and the headless implementation below is
/// what the conformance rig and tests drive.
///
/// Contract: [feed] takes bytes arriving from the SSH channel; [userInput]
/// emits bytes the user produced (keystrokes, paste) to be sent to SSH.
abstract class TerminalEngine {
  void feed(Uint8List data);
  Stream<Uint8List> get userInput;
  TerminalSize get size;
  void resize(TerminalSize size);
  Future<void> dispose();
}

/// A terminal engine with no rendering: it accumulates everything fed to it and
/// lets a test/harness push input. Used by the headless conformance rig to
/// assert on what a session produced, and to wire-test the SSH plumbing.
class HeadlessTerminalEngine implements TerminalEngine {
  final BytesBuilder _received = BytesBuilder();
  final StreamController<Uint8List> _input =
      StreamController<Uint8List>.broadcast();
  TerminalSize _size;

  HeadlessTerminalEngine([this._size = const TerminalSize(80, 24)]);

  /// Everything fed so far, as raw bytes.
  Uint8List get received => _received.toBytes();

  /// Everything fed so far, decoded as UTF-8 (lossy) — handy for assertions.
  String get receivedText => utf8.decode(received, allowMalformed: true);

  /// Simulate the user typing/pasting.
  void type(String text) => _input.add(Uint8List.fromList(utf8.encode(text)));

  @override
  void feed(Uint8List data) => _received.add(data);

  @override
  Stream<Uint8List> get userInput => _input.stream;

  @override
  TerminalSize get size => _size;

  @override
  void resize(TerminalSize size) => _size = size;

  @override
  Future<void> dispose() async {
    await _input.close();
  }
}

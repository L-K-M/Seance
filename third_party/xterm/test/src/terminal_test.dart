import 'package:test/test.dart';
import 'package:xterm/core.dart';

void main() {
  test('cursor position reports use one-based rows and columns', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[6n');
    terminal.write('\x1b[3;5H\x1b[6n');

    expect(output, ['\x1b[1;1R', '\x1b[3;5R']);
  });

  test('cursor reports stay inside the viewport at the wrap boundary', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add)..resize(6, 2);

    terminal.write('123456\x1b[6n');
    terminal.write('7\x1b[6n');

    expect(output, ['\x1b[1;6R', '\x1b[2;2R']);
  });

  test('cursor reports respect the origin within scrolling margins', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add)..resize(10, 10);

    terminal.write('\x1b[3;8r\x1b[?6h\x1b[3;5H\x1b[6n');
    terminal.write('\x1b[?6l\x1b[5;5H\x1b[6n');

    expect(output, ['\x1b[3;5R', '\x1b[5;5R']);
  });

  test('changing origin mode homes the cursor within its new coordinates', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add)..resize(10, 10);

    terminal.write('\x1b[3;8r\x1b[?6h\x1b[6n');
    expect(terminal.buffer.cursorY, 2);
    terminal.write('\x1b[3;5H\x1b[?6l\x1b[6n');
    expect(terminal.buffer.cursorY, 0);

    expect(output, ['\x1b[1;1R', '\x1b[1;1R']);
  });

  test('changing scrolling margins homes the cursor in origin mode', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add)..resize(10, 10);

    terminal.write('\x1b[?6h\x1b[3;8r\x1b[6n');
    expect(terminal.buffer.cursorY, 2);
    expect(output, ['\x1b[1;1R']);
  });

  test('origin-relative reports stay valid after viewport cursor controls', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add)..resize(10, 10);

    terminal.write('\x1b[3;8r\x1b[?6h\x1b[999A\x1b[6n');
    terminal.write('\x1b[999B\x1b[6n');

    expect(output, ['\x1b[1;1R', '\x1b[6;1R']);
  });

  group('Terminal.inputHandler', () {
    test('can be set to null', () {
      final terminal = Terminal(inputHandler: null);
      expect(() => terminal.keyInput(TerminalKey.keyA), returnsNormally);
    });

    test('can be changed', () {
      final handler1 = _TestInputHandler();
      final handler2 = _TestInputHandler();
      final terminal = Terminal(inputHandler: handler1);

      terminal.keyInput(TerminalKey.keyA);
      expect(handler1.events, isNotEmpty);

      terminal.inputHandler = handler2;

      terminal.keyInput(TerminalKey.keyA);
      expect(handler2.events, isNotEmpty);
    });
  });

  group('Terminal.mouseInput', () {
    test('can handle mouse events', () {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(10, 10),
      );

      expect(output, isEmpty);

      // enable mouse reporting
      terminal.write('\x1b[?1000h');

      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(10, 10),
      );

      expect(output, ['\x1B[M +,']);
    });
  });

  group('Terminal.reflowEnabled', () {
    test('prevents reflow when set to false', () {
      final terminal = Terminal(reflowEnabled: false);

      terminal.write('Hello World');
      terminal.resize(5, 5);

      expect(terminal.buffer.lines[0].toString(), 'Hello');
      expect(terminal.buffer.lines[1].toString(), isEmpty);
    });

    test('preserves hidden cells when reflow is disabled', () {
      final terminal = Terminal(reflowEnabled: false);

      terminal.write('Hello World');
      terminal.resize(5, 5);
      terminal.resize(20, 5);

      expect(terminal.buffer.lines[0].toString(), 'Hello World');
      expect(terminal.buffer.lines[1].toString(), isEmpty);
    });

    test('can be set at runtime', () {
      final terminal = Terminal(reflowEnabled: true);

      terminal.resize(5, 5);
      terminal.write('Hello World');
      terminal.reflowEnabled = false;
      terminal.resize(20, 5);

      expect(terminal.buffer.lines[0].toString(), 'Hello');
      expect(terminal.buffer.lines[1].toString(), ' Worl');
      expect(terminal.buffer.lines[2].toString(), 'd');
    });
  });

  group('Terminal.mouseInput', () {
    test('applys to the main buffer', () {
      final terminal = Terminal(
        wordSeparators: {
          'z'.codeUnitAt(0),
        },
      );

      expect(
        terminal.mainBuffer.wordSeparators,
        contains('z'.codeUnitAt(0)),
      );
    });

    test('applys to the alternate buffer', () {
      final terminal = Terminal(
        wordSeparators: {
          'z'.codeUnitAt(0),
        },
      );

      expect(
        terminal.altBuffer.wordSeparators,
        contains('z'.codeUnitAt(0)),
      );
    });
  });

  group('Terminal.onPrivateOSC', () {
    test(r'works with \a end', () {
      String? lastCode;
      List<String>? lastData;

      final terminal = Terminal(
        onPrivateOSC: (String code, List<String> data) {
          lastCode = code;
          lastData = data;
        },
      );

      terminal.write('\x1b]6\x07');

      expect(lastCode, '6');
      expect(lastData, []);

      terminal.write('\x1b]66;hello world\x07');

      expect(lastCode, '66');
      expect(lastData, ['hello world']);

      terminal.write('\x1b]666;hello;world\x07');

      expect(lastCode, '666');
      expect(lastData, ['hello', 'world']);

      terminal.write('\x1b]hello;world\x07');

      expect(lastCode, 'hello');
      expect(lastData, ['world']);
    });

    test(r'works with \x1b\ end', () {
      String? lastCode;
      List<String>? lastData;

      final terminal = Terminal(
        onPrivateOSC: (String code, List<String> data) {
          lastCode = code;
          lastData = data;
        },
      );

      terminal.write('\x1b]6\x1b\\');

      expect(lastCode, '6');
      expect(lastData, []);

      terminal.write('\x1b]66;hello world\x1b\\');

      expect(lastCode, '66');
      expect(lastData, ['hello world']);

      terminal.write('\x1b]666;hello;world\x1b\\');

      expect(lastCode, '666');
      expect(lastData, ['hello', 'world']);

      terminal.write('\x1b]hello;world\x1b\\');

      expect(lastCode, 'hello');
      expect(lastData, ['world']);
    });

    test('do not receive common osc', () {
      String? lastCode;
      List<String>? lastData;

      final terminal = Terminal(
        onPrivateOSC: (String code, List<String> data) {
          lastCode = code;
          lastData = data;
        },
      );

      terminal.write('\x1b]0;hello world\x07');

      expect(lastCode, isNull);
      expect(lastData, isNull);
    });
  });
}

class _TestInputHandler implements TerminalInputHandler {
  final events = <TerminalKeyboardEvent>[];

  @override
  String? call(TerminalKeyboardEvent event) {
    events.add(event);
    return null;
  }
}

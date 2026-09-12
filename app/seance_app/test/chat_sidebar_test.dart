import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/chat_session.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/chat_sidebar.dart';
import 'package:seance_core/seance_core.dart';

class _Provider implements LlmProvider {
  int requests = 0;
  Completer<ChatTurn>? pending;

  @override
  Future<ChatTurn> chat({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
  }) async {
    requests++;
    if (pending case final pending?) return pending.future;
    if (requests.isEven) return const ChatTurn(text: 'Ready.');
    return const ChatTurn(
      text: '',
      toolCalls: [
        ToolCall(
          id: 'paste',
          name: 'paste_to_prompt',
          arguments: {'command': 'pwd'},
        ),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Services implements AppServices {
  final _Provider provider = _Provider();
  int builds = 0;
  @override
  final AppSettings settings = AppSettings();
  @override
  Future<LlmProvider> buildLlmProvider() async {
    builds++;
    return provider;
  }

  @override
  Future<SearchProvider?> buildSearchProvider() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements TerminalSession {
  @override
  final String id;
  @override
  final XtermTerminalEngine engine = XtermTerminalEngine();
  _Session(this.id);
  @override
  bool get isConnected => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _State extends ChangeNotifier implements AppState {
  @override
  final _Services services = _Services();
  @override
  final ChatSession chat = ChatSession();
  @override
  int get llmConfigVersion => 0;
  @override
  _Session? activeSession;
  final List<_Session> terminals = [];
  @override
  TerminalSession? sessionById(String? id) =>
      terminals.where((session) => session.id == id).firstOrNull;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _State state;
  late _Session first;
  late _Session second;
  late List<String> firstInput;
  late List<String> secondInput;

  setUp(() {
    state = _State();
    first = _Session('first');
    second = _Session('second');
    state.terminals.addAll([first, second]);
    state.activeSession = first;
    firstInput = [];
    secondInput = [];
    first.engine.userInput.listen(
      (bytes) => firstInput.add(utf8.decode(bytes)),
    );
    second.engine.userInput.listen(
      (bytes) => secondInput.add(utf8.decode(bytes)),
    );
  });

  tearDown(() async {
    state.chat.dispose();
    state.dispose();
    await first.engine.dispose();
    await second.engine.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          state: state,
          child: const Scaffold(body: ChatSidebar()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
  }

  testWidgets('a remounted sidebar stages into the current turn target', (
    tester,
  ) async {
    await mount(tester);
    await send(tester, 'first turn');
    await tester.pumpAndSettle();
    expect(firstInput, ['pwd']);

    await tester.pumpWidget(const SizedBox());
    state.activeSession = second;
    await mount(tester);
    await send(tester, 'second turn');
    await tester.pumpAndSettle();

    expect(state.services.builds, 1, reason: 'the conversation is retained');
    expect(firstInput, ['pwd']);
    expect(secondInput, ['pwd']);
    expect(state.chat.entries, hasLength(4));
  });

  testWidgets('reset prevents a late tool from targeting the next turn', (
    tester,
  ) async {
    final oldReply = Completer<ChatTurn>();
    state.services.provider.pending = oldReply;
    await mount(tester);
    await send(tester, 'old turn');
    expect(state.services.provider.requests, 1);

    await tester.tap(find.byTooltip('New chat'));
    await tester.pump();
    final newReply = Completer<ChatTurn>();
    state.services.provider.pending = newReply;
    state.activeSession = second;
    await send(tester, 'new turn');
    expect(state.services.provider.requests, 2);

    oldReply.complete(
      const ChatTurn(
        text: '',
        toolCalls: [
          ToolCall(
            id: 'late',
            name: 'paste_to_prompt',
            arguments: {'command': 'old'},
          ),
        ],
      ),
    );
    await tester.pump();
    expect(firstInput, isEmpty);
    expect(secondInput, isEmpty);
    expect(state.services.provider.requests, 2);
    newReply.complete(const ChatTurn(text: 'New answer.'));
    await tester.pumpAndSettle();
    expect(state.chat.entries.map((entry) => entry.text), [
      'new turn',
      'New answer.',
    ]);
  });
}

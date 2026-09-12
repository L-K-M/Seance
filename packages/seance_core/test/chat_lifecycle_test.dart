import 'dart:async';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

class _Provider implements LlmProvider {
  final List<List<LlmMessage>> requests = [];
  Future<ChatTurn> Function() answer;
  _Provider(this.answer);

  @override
  Future<ChatTurn> chat({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
  }) {
    requests.add(messages);
    return answer();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Search implements SearchProvider {
  final started = Completer<void>();
  final result = Completer<List<SearchResult>>();
  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) {
    started.complete();
    return result.future;
  }
}

void main() {
  test(
    'terminal context stays within the turn that opted into sharing it',
    () async {
      var requests = 0;
      final provider = _Provider(() async {
        requests++;
        if (requests == 1) {
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
        return const ChatTurn(text: 'answer');
      });
      final controller = ChatController(provider: provider, onPaste: (_) {});
      await controller.send(
        'first question',
        terminalContext: 'private terminal output',
      );
      await controller.send('second question');

      for (final request in provider.requests.take(2)) {
        expect(
          request.map((message) => message.content).join('\n'),
          contains('private terminal output'),
        );
      }
      final nextRequest = provider.requests.last
          .map((message) => message.content)
          .join('\n');
      expect(nextRequest, contains('first question'));
      expect(nextRequest, isNot(contains('private terminal output')));
    },
  );

  test(
    'reset discards a late reply without contaminating new history',
    () async {
      final lateReply = Completer<ChatTurn>();
      final provider = _Provider(() => lateReply.future);
      final controller = ChatController(provider: provider, onPaste: (_) {});
      final oldTurn = controller.send('old question');
      final cancelled = expectLater(oldTurn, throwsStateError);
      controller.reset();
      provider.answer = () async => const ChatTurn(text: 'new answer');
      await controller.send('new question');

      lateReply.complete(const ChatTurn(text: 'old answer'));
      await cancelled;
      await controller.send('follow-up');
      expect(provider.requests.last.map((message) => message.content), [
        kChatSystemPrompt,
        'new question',
        'new answer',
        'follow-up',
      ]);
    },
  );

  test(
    'reset during search prevents later tools and continuation requests',
    () async {
      final provider = _Provider(
        () async => const ChatTurn(
          text: '',
          toolCalls: [
            ToolCall(
              id: 'search',
              name: 'web_search',
              arguments: {'query': 'help'},
            ),
            ToolCall(
              id: 'paste',
              name: 'paste_to_prompt',
              arguments: {'command': 'pwd'},
            ),
          ],
        ),
      );
      final search = _Search();
      final pasted = <String>[];
      final controller = ChatController(
        provider: provider,
        searchProvider: search,
        onPaste: pasted.add,
      );
      final turn = controller.send('old question');
      final cancelled = expectLater(turn, throwsStateError);
      await search.started.future;
      controller.reset();
      search.result.complete(const []);
      await cancelled;

      expect(pasted, isEmpty);
      expect(provider.requests, hasLength(1));
      expect(controller.historyLength, 0);
    },
  );
}

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

/// One turn in the assistant transcript, as the sidebar renders it.
@immutable
class ChatEntry {
  final bool fromUser;
  final String text;

  /// Commands the assistant placed in the prompt this turn.
  final List<String> staged;

  /// Web searches it ran this turn.
  final List<String> searches;

  const ChatEntry({
    required this.fromUser,
    required this.text,
    this.staged = const [],
    this.searches = const [],
  });
}

/// The assistant conversation, held outside the widget tree.
///
/// The sidebar used to own both the transcript and the [ChatController] (which
/// carries the provider-side history). On narrow layouts the sidebar lives in a
/// `Drawer`, so **closing the drawer destroyed the conversation** — and on a
/// phone the drawer is the only way to reach the assistant, which made it
/// effectively single-turn there. Crossing the wide/narrow breakpoint on the
/// desktop did the same thing.
///
/// Holding it here means the drawer is a view onto state that outlives it. The
/// conversation is deliberately in memory only: terminal context and assistant
/// replies are exactly the kind of thing that should not silently accumulate on
/// disk, so a relaunch still starts clean.
class ChatSession extends ChangeNotifier {
  final List<ChatEntry> _entries = [];
  ChatController? _controller;

  /// The `llmConfigVersion` [_controller] was built with, so a provider change
  /// in Settings rebuilds it instead of reusing a stale key or model.
  int? _controllerVersion;

  bool _sending = false;
  String? _error;

  /// Bumped by [reset]. A turn that was in flight when the user started a new
  /// conversation carries the old generation, so its reply is dropped instead
  /// of landing in the freshly cleared transcript.
  int _generation = 0;
  bool _disposed = false;

  List<ChatEntry> get entries => List.unmodifiable(_entries);
  bool get sending => _sending;
  String? get error => _error;
  bool get isEmpty => _entries.isEmpty;

  /// Whether asynchronous work still belongs to this live conversation.
  bool isCurrentTurn(int turn) => !_disposed && turn == _generation;

  /// The live controller, or null when one has not been built yet or the
  /// provider settings have changed since it was.
  ChatController? controllerFor(int configVersion) =>
      _controllerVersion == configVersion ? _controller : null;

  /// Adopt a freshly built controller for [configVersion].
  ///
  /// The visible transcript is kept, but the new controller starts with no
  /// provider-side history: replaying earlier turns would ship a conversation
  /// held with one provider to whichever one the user just switched to.
  void adoptController(ChatController controller, int configVersion) {
    _controller = controller;
    _controllerVersion = configVersion;
  }

  /// Start a turn. The returned token identifies it; pass it back to the
  /// methods below so a turn that outlived a [reset] cannot write to the new
  /// conversation.
  int addUserMessage(String text) {
    _entries.add(ChatEntry(fromUser: true, text: text));
    _error = null;
    _sending = true;
    notifyListeners();
    return _generation;
  }

  void addReply(int turn, ChatResult result) {
    if (!isCurrentTurn(turn)) return;
    _entries.add(
      ChatEntry(
        fromUser: false,
        text: result.reply,
        staged: result.stagedCommands,
        searches: result.searchQueries,
      ),
    );
    notifyListeners();
  }

  void failed(int turn, Object error) {
    if (!isCurrentTurn(turn)) return;
    _error = error.toString();
    notifyListeners();
  }

  void finishSending(int turn) {
    if (!isCurrentTurn(turn) || !_sending) return;
    _sending = false;
    notifyListeners();
  }

  /// Start a new conversation: clears the transcript and the provider history.
  ///
  /// Safe mid-flight. The composer stops showing a send in progress, and the
  /// turn still awaiting a reply is orphaned by the generation bump rather
  /// than dropping its answer into the empty conversation.
  void reset() {
    _generation++;
    _entries.clear();
    _error = null;
    _sending = false;
    _controller?.reset();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.reset();
    super.dispose();
  }
}

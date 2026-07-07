import 'package:seance_protocol/seance_protocol.dart';

/// The outcome of checking a server's presented host key against what we have
/// pinned. This drives the TOFU UX: [firstUse] shows a fingerprint-confirm
/// dialog, [changed] shows a hard "HOST KEY CHANGED" block, and [trusted]
/// connects silently.
enum HostKeyVerdict { trusted, firstUse, changed }

class HostKeyDecision {
  final HostKeyVerdict verdict;

  /// The key presented by the server on this connection.
  final HostKey presented;

  /// The previously pinned key, when one exists (for [trusted]/[changed]).
  final HostKey? pinned;

  const HostKeyDecision({
    required this.verdict,
    required this.presented,
    this.pinned,
  });

  bool get isTrusted => verdict == HostKeyVerdict.trusted;
  bool get isChanged => verdict == HostKeyVerdict.changed;
}

/// Persistence for pinned host keys. The app backs this with SQLite (and syncs
/// it); tests use an in-memory implementation.
abstract class HostKeyStore {
  Future<HostKey?> get(String host, int port);
  Future<void> put(HostKey key);
  Future<List<HostKey>> all();
}

/// Trust-on-first-use verification. Note it never pins automatically on a
/// change — a changed key returns [HostKeyVerdict.changed] and requires the
/// user to explicitly re-pin via [pin], exactly as the design demands.
class TofuVerifier {
  final HostKeyStore store;
  const TofuVerifier(this.store);

  Future<HostKeyDecision> check(HostKey presented) async {
    final pinned = await store.get(presented.host, presented.port);
    if (pinned == null) {
      return HostKeyDecision(
          verdict: HostKeyVerdict.firstUse, presented: presented);
    }
    if (pinned.fingerprintSha256 == presented.fingerprintSha256) {
      return HostKeyDecision(
          verdict: HostKeyVerdict.trusted,
          presented: presented,
          pinned: pinned);
    }
    return HostKeyDecision(
        verdict: HostKeyVerdict.changed,
        presented: presented,
        pinned: pinned);
  }

  /// Pin (or re-pin) a key after the user has explicitly confirmed it.
  Future<void> pin(HostKey key) => store.put(key);
}

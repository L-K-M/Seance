// The two tests that build dartssh2's real userauth messages, apart from the
// rest of the diagnostics suite: they import a `src/` file of the dependency,
// so an internal file move in a dartssh2 release stops *this* file compiling
// and nothing else — the blast radius is exactly the tests that depend on
// the internals, which is what makes that failure a signal.
//
// Pinning the exact toString dartssh2 prints is the point: the barrel does not
// export the message, and asserting against a hand-written copy of it would
// prove the pattern against itself rather than against the dependency. The
// lint is not enabled in this workspace, so the directive below is for
// whenever it is, and has to be the line immediately above the import with
// nothing after the code — prose beside it suppresses nothing.
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_userauth.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  group('connection-log redaction against the real dartssh2 messages', () {
    test('the real message dartssh2 sends is the shape this scrubs', () {
      // The one assertion that is not written against my reading of dartssh2:
      // it builds the message the client actually sends and redacts its own
      // toString, so an upgrade that changes the format fails here rather
      // than at the fail-closed branch in production.
      final log = SshConnectionLog();
      log.add('-> sock: '
          '${SSH_Message_Userauth_InfoResponse(responses: const [
            'hunter2',
            'second-answer',
          ])}');
      expect(log.toString(), isNot(contains('hunter2')));
      expect(log.toString(), isNot(contains('second-answer')));
      expect(log.toString(), contains('[redacted])'));
      expect(log.toString(), isNot(contains('does not recognize')));
    });

    test('the real password request never carries the password either', () {
      // The *other* secret-bearing message. dartssh2 omits the password from
      // `SSH_Message_Userauth_Request.toString()` today, so nothing has to
      // scrub it — and until now nothing checked that, so an upgrade that
      // started printing it would put a plaintext password into a transcript
      // this feature shows with a Copy button and invites people to paste
      // into bug reports. Built from the real message for the same reason the
      // InfoResponse one is: a hand-written line would pin my reading of
      // dartssh2 rather than dartssh2.
      final log = SshConnectionLog();
      log.add('-> sock: '
          '${SSH_Message_Userauth_Request.password(
            user: 'deploy',
            password: 'hunter2',
          )}');
      expect(log.toString(), isNot(contains('hunter2')));
      expect(log.toString(), contains('deploy'));
    });
  });
}

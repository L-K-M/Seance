import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/server_editor.dart';
import 'package:seance_core/seance_core.dart';

/// What a Save writes for the credential boxes, decided away from the widget
/// so each combination can be asserted directly.
void main() {
  group('plannedCredential', () {
    Secret? plan({
      AuthMethod auth = AuthMethod.privateKey,
      bool referenceKeyFile = true,
      String password = '',
      String keyPem = '',
      String keyPassphrase = '',
      Secret? stored,
    }) =>
        plannedCredential(
          auth: auth,
          referenceKeyFile: referenceKeyFile,
          password: password,
          keyPem: keyPem,
          keyPassphrase: keyPassphrase,
          secretId: 'sec-1',
          stored: stored,
        );

    test('a referenced key stores the passphrase that decrypts it', () {
      // The box is shown in this mode and used to be dropped: `Test
      // connection` authenticates with what was typed, so it reported success
      // for a key the saved server could not decrypt.
      final secret = plan(keyPassphrase: 'hunter2');
      expect(secret, isNotNull);
      expect(secret!.keyPassphrase, 'hunter2');
      expect(secret.id, 'sec-1');
      // The key itself stays on disk.
      expect(secret.value, isEmpty);
    });

    test('a PEM stored under the same entry survives the passphrase write',
        () {
      // Switching to a referenced file leaves the stored key unread, not
      // discarded — switching back has to find it again.
      final secret = plan(
        keyPassphrase: 'hunter2',
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.privateKey,
          value: 'PEM',
        ),
      );
      expect(secret!.value, 'PEM');
      expect(secret.keyPassphrase, 'hunter2');
      // And the pair that leaves behind: the carried PEM was stored with its
      // own passphrase, and this write replaces it with the referenced key's.
      // Pinned as the documented behaviour rather than as a desirable one —
      // one entry holds one passphrase, and the referenced key is the one the
      // server is set to use. STATUS follow-up 17.
    });

    test('a typed PEM does not inherit the stored passphrase', () {
      // The mirror of the case above, and the other half of the single-slot
      // problem: a newly pasted key brings its own passphrase, so a blank box
      // beside it means "none", not "keep". Dropping it is deliberate —
      // carrying one key's passphrase onto another is what makes an entry
      // undecryptable — but nothing pinned it, and the fuzz's fixture has no
      // stored passphrase to notice with.
      final secret = plan(
        referenceKeyFile: false,
        keyPem: 'NEW PEM',
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.privateKey,
          value: 'OLD PEM',
          keyPassphrase: 'belongs to the old key',
        ),
      );
      expect(secret!.value, 'NEW PEM');
      expect(secret.keyPassphrase, isNull);
    });

    test('a blank box keeps whatever is stored, in every mode', () {
      // With something stored, which is the case the name is about: nothing
      // written means the entry is left as it is, and a plan built from it
      // would be a write nobody asked for.
      const stored =
          Secret(id: 'sec-1', kind: SecretKind.privateKey, value: 'PEM');
      expect(plan(), isNull);
      expect(plan(stored: stored), isNull);
      expect(plan(referenceKeyFile: false, stored: stored), isNull);
      expect(plan(auth: AuthMethod.password, stored: stored), isNull);
      // The agent has no credential of its own to write.
      expect(plan(auth: AuthMethod.agent, keyPassphrase: 'x'), isNull);
    });

    test('a typed key carries its passphrase, or none', () {
      final withPass =
          plan(referenceKeyFile: false, keyPem: 'PEM', keyPassphrase: 'p');
      expect(withPass!.value, 'PEM');
      expect(withPass.keyPassphrase, 'p');
      final without = plan(referenceKeyFile: false, keyPem: 'PEM');
      expect(without!.keyPassphrase, isNull);
    });

    test('a stored password is not carried into a key entry', () {
      // The entry under this id belongs to whatever auth method last wrote
      // it. A server that used a password before would otherwise have that
      // password stored as its PEM, and read back as one the next time the
      // key was typed rather than referenced.
      final secret = plan(
        keyPassphrase: 'hunter2',
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.password,
          value: 'the old password',
        ),
      );
      // The kind as well as the fields: an entry that kept the old
      // `password` stamp while carrying a passphrase is the same
      // contamination one label along, and a read that dispatches on `kind`
      // would take the passphrase for a password.
      expect(secret!.kind, SecretKind.privateKey);
      expect(secret.value, isEmpty);
      expect(secret.keyPassphrase, 'hunter2');
    });

    test('a password is stored as one', () {
      final secret = plan(auth: AuthMethod.password, password: 'pw');
      expect(secret!.kind, SecretKind.password);
      expect(secret.value, 'pw');
    });

    test('plannedCredentialReadsStored covers every branch that reads it', () {
      // `_save` fetches the vault entry only where the predicate says it is
      // needed, so the two have to agree by construction rather than by
      // convention: widen the carry-over without widening the predicate and
      // `stored` arrives null on a branch that dereferences it, writing an
      // empty PEM over a real key.
      //
      // Fuzzed rather than enumerated by hand, so a branch added later is
      // covered without anyone remembering to list it.
      const stored = Secret(
        id: 'sec-1',
        kind: SecretKind.privateKey,
        value: 'STORED PEM',
      );
      for (final auth in AuthMethod.values) {
        for (final referenceKeyFile in [true, false]) {
          for (final password in ['', 'pw']) {
            for (final keyPem in ['', 'TYPED PEM']) {
              for (final keyPassphrase in ['', 'pass']) {
                final reads = plannedCredentialReadsStored(
                  auth: auth,
                  referenceKeyFile: referenceKeyFile,
                  keyPassphrase: keyPassphrase,
                );
                Secret? call({Secret? with_}) => plan(
                      auth: auth,
                      referenceKeyFile: referenceKeyFile,
                      password: password,
                      keyPem: keyPem,
                      keyPassphrase: keyPassphrase,
                      stored: with_,
                    );
                final withStored = call(with_: stored);
                final without = call();
                final combination = 'auth=$auth reference=$referenceKeyFile '
                    'password="$password" pem="$keyPem" '
                    'passphrase="$keyPassphrase"';
                if (reads) {
                  // The predicate promises the entry matters here, so a plan
                  // made without it has to differ — otherwise the fetch is
                  // dead weight and the promise is empty.
                  // The whole plan, as the comment above says: a branch
                  // where the entry mattered only for the passphrase would
                  // otherwise fail this for the wrong reason. Not weaker in
                  // practice — the passphrase comes from the form, so a
                  // carry-over that stopped carrying leaves both equal.
                  expect(
                    withStored?.value != without?.value ||
                        withStored?.keyPassphrase != without?.keyPassphrase,
                    isTrue,
                    reason: 'reads stored, yet ignores it: $combination',
                  );
                } else {
                  // `kind` as well: a carry-over that took the stored
                  // entry's kind would stamp a private key as a password —
                  // the cross-method contamination the neighbouring tests are
                  // about — and the two fields below would not notice.
                  expect(withStored?.kind, without?.kind,
                      reason: 'reads stored without saying so: $combination');
                  expect(withStored?.value, without?.value,
                      reason: 'reads stored without saying so: $combination');
                  expect(withStored?.keyPassphrase, without?.keyPassphrase,
                      reason: 'reads stored without saying so: $combination');
                }
              }
            }
          }
        }
      }
    });
  });
}

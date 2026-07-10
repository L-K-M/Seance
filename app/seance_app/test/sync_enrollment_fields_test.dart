import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/settings_screen.dart';
import 'package:seance_app/ui/sync_enrollment_validation.dart';

void main() {
  late TextEditingController password;
  late TextEditingController encryptionPassphrase;
  late TextEditingController confirmation;

  setUp(() {
    password = TextEditingController();
    encryptionPassphrase = TextEditingController();
    confirmation = TextEditingController();
  });

  tearDown(() {
    password.dispose();
    encryptionPassphrase.dispose();
    confirmation.dispose();
  });

  Future<void> pumpFields(WidgetTester tester, SyncEnrollmentMode mode) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SyncEnrollmentFields(
              mode: mode,
              passwordController: password,
              encryptionPassphraseController: encryptionPassphrase,
              confirmationController: confirmation,
            ),
          ),
        ),
      );

  testWidgets('login shows both required secrets without confirmation', (
    tester,
  ) async {
    await pumpFields(tester, SyncEnrollmentMode.login);

    expect(find.text('Account password'), findsOneWidget);
    expect(find.text('Vault encryption passphrase'), findsOneWidget);
    expect(find.text('Confirm vault encryption passphrase'), findsNothing);
  });

  testWidgets('registration adds encryption passphrase confirmation', (
    tester,
  ) async {
    await pumpFields(tester, SyncEnrollmentMode.register);

    expect(find.text('Account password'), findsOneWidget);
    expect(find.text('Vault encryption passphrase'), findsOneWidget);
    expect(find.text('Confirm vault encryption passphrase'), findsOneWidget);
  });
}

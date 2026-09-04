import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

class _TrackedClient extends MockClient {
  _TrackedClient() : super((_) async => http.Response('{}', HttpStatus.ok));
  int closes = 0;

  @override
  void close() {
    closes++;
    super.close();
  }
}

void main() {
  test('internally created transport closes exactly once', () {
    final transport = _TrackedClient();
    final sync = http.runWithClient(
        () => HttpSyncClient(baseUrl: 'https://sync.test'), () => transport);
    sync.close();
    sync.close();
    expect(transport.closes, 1);
  });

  test('borrowed transport survives wrapper disposal', () async {
    final transport = _TrackedClient();
    addTearDown(transport.close);
    final sync = HttpSyncClient(baseUrl: 'https://sync.test', client: transport);
    sync.close();
    sync.close();
    expect(transport.closes, 0);
    expect((await transport.get(Uri.parse('https://other.test'))).statusCode,
        HttpStatus.ok);
    await expectLater(sync.pull(since: 0), throwsStateError);
  });
}

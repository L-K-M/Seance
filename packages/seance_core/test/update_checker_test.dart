import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  group('AppVersion', () {
    test('parses, tolerating a leading v and whitespace', () {
      expect(AppVersion.tryParse('v1.2.3').toString(), '1.2.3');
      expect(AppVersion.tryParse('  0.2.0 ').toString(), '0.2.0');
      expect(AppVersion.tryParse('V2.0').toString(), '2.0');
    });

    test('drops a pre-release / build suffix', () {
      expect(AppVersion.tryParse('1.2.3-rc.1').toString(), '1.2.3');
      expect(AppVersion.tryParse('1.2.3+42').toString(), '1.2.3');
    });

    test('returns null for unparseable input', () {
      expect(AppVersion.tryParse(null), isNull);
      expect(AppVersion.tryParse(''), isNull);
      expect(AppVersion.tryParse('latest'), isNull);
      expect(AppVersion.tryParse('v'), isNull);
    });

    test('compares numerically, not lexically', () {
      expect(AppVersion.isNewer(current: '0.9.0', candidate: '0.10.0'), isTrue);
      expect(AppVersion.isNewer(current: '1.2.0', candidate: '1.2.1'), isTrue);
      expect(AppVersion.isNewer(current: '2.0.0', candidate: '1.9.9'), isFalse);
    });

    test('treats missing trailing components as zero', () {
      expect(AppVersion.isNewer(current: '1.2', candidate: '1.2.0'), isFalse);
      expect(AppVersion.isNewer(current: '1.2', candidate: '1.2.1'), isTrue);
      expect(AppVersion('1.2.0'.split('.').map(int.parse).toList()),
          AppVersion([1, 2]));
    });

    test('an equal version is not newer', () {
      expect(AppVersion.isNewer(current: '0.2.0', candidate: 'v0.2.0'), isFalse);
    });

    test('unparseable versions never read as newer (safe default)', () {
      expect(AppVersion.isNewer(current: '0.2.0', candidate: 'garbage'),
          isFalse);
      expect(AppVersion.isNewer(current: null, candidate: '9.9.9'), isFalse);
    });
  });

  group('UpdateChecker', () {
    UpdateChecker checkerReturning(String body, {int status = 200}) {
      return UpdateChecker(
        client: MockClient((req) async {
          expect(req.url.toString(),
              'https://api.github.com/repos/L-K-M/Seance/releases/latest');
          expect(req.headers['User-Agent'], isNotNull); // GitHub 403s without it
          return http.Response(body, status);
        }),
      );
    }

    test('reports an update when the latest tag is newer', () async {
      final checker = checkerReturning(jsonEncode({'tag_name': 'v0.3.0'}));
      final info = await checker.check('0.2.0');
      expect(info, isNotNull);
      expect(info!.latestVersion, '0.3.0');
      expect(info.releasesUrl.toString(),
          'https://github.com/L-K-M/Seance/releases/latest');
    });

    test('reports nothing when up to date', () async {
      final checker = checkerReturning(jsonEncode({'tag_name': 'v0.2.0'}));
      expect(await checker.check('0.2.0'), isNull);
    });

    test('reports nothing when the running version is newer', () async {
      final checker = checkerReturning(jsonEncode({'tag_name': 'v0.1.0'}));
      expect(await checker.check('0.2.0'), isNull);
    });

    test('ignores drafts and prereleases', () async {
      final draft = checkerReturning(
          jsonEncode({'tag_name': 'v0.3.0', 'draft': true}));
      expect(await draft.check('0.2.0'), isNull);
      final pre = checkerReturning(
          jsonEncode({'tag_name': 'v0.3.0', 'prerelease': true}));
      expect(await pre.check('0.2.0'), isNull);
    });

    test('a 404 (no releases yet) is silent, not an error', () async {
      final checker = checkerReturning('Not Found', status: 404);
      expect(await checker.check('0.2.0'), isNull);
    });

    test('a 403 (rate-limited) is silent', () async {
      final checker = checkerReturning('rate limited', status: 403);
      expect(await checker.check('0.2.0'), isNull);
    });

    test('malformed JSON is swallowed', () async {
      final checker = checkerReturning('not json at all');
      expect(await checker.check('0.2.0'), isNull);
    });

    test('a network error is swallowed', () async {
      final checker = UpdateChecker(
        client: MockClient((req) => throw const SocketExceptionStub()),
      );
      expect(await checker.check('0.2.0'), isNull);
    });

    test('a hung request times out and reports nothing', () async {
      final checker = UpdateChecker(
        timeout: const Duration(milliseconds: 20),
        client: MockClient((req) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return http.Response('{}', 200);
        }),
      );
      expect(await checker.check('0.2.0'), isNull);
    });
  });
}

/// A stand-in throwable so the test doesn't depend on dart:io.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}

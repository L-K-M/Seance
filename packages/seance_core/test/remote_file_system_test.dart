import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  group('remote POSIX paths', () {
    test('joins names without damaging root or relative paths', () {
      expect(remoteJoin('/', 'file.txt'), '/file.txt');
      expect(remoteJoin('/srv/www/', 'file.txt'), '/srv/www/file.txt');
      expect(remoteJoin('.', 'file.txt'), 'file.txt');
      expect(remoteJoin('', 'file.txt'), 'file.txt');
    });

    test('finds parent and basename at root and below it', () {
      expect(remoteBasename('/srv/www/file.txt'), 'file.txt');
      expect(remoteBasename('/srv/www/'), 'www');
      expect(remoteParent('/srv/www/file.txt'), '/srv/www');
      expect(remoteParent('/file.txt'), '/');
      expect(remoteParent('/'), '/');
      expect(remoteParent('file.txt'), '.');
    });
  });

  test('transfer cancellation is sticky', () {
    final cancellation = RemoteTransferCancellation();
    expect(cancellation.isCancelled, isFalse);
    cancellation.throwIfCancelled();
    cancellation.cancel();
    expect(cancellation.isCancelled, isTrue);
    expect(cancellation.throwIfCancelled, throwsA(anything));
  });
}

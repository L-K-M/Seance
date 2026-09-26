import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

const _agentSocketVariable = 'SSH_AUTH_SOCK';
const _windowsAgentPipe = r'\\.\pipe\openssh-ssh-agent';

// OpenSSH bounds replies to keep a local agent from exhausting its client.
const _maxAgentMessageBytes = 256 * 1024;
const _maxAgentIdentities = 2048;
const _agentRequestTimeout = Duration(minutes: 5);
const _windowsPipeConnectTimeout = Duration(seconds: 15);
const _windowsPipeRetryInterval = Duration(seconds: 1);

const _agentFailure = 5;
const _requestIdentities = 11;
const _identitiesAnswer = 12;
const _signRequest = 13;
const _signResponse = 14;

const _rsaPublicKeyType = 'ssh-rsa';
const _rsaSha256Type = 'rsa-sha2-256';
const _rsaCertificateType = 'ssh-rsa-cert-v01@openssh.com';
const _rsaSha256CertificateType = 'rsa-sha2-256-cert-v01@openssh.com';
const _rsaSha256Flag = 2;

const _frameHeaderBytes = 4;

/// Exchanges one length-prefixed OpenSSH agent message.
typedef SshAgentExchange = Future<Uint8List> Function(Uint8List request);

/// A local ssh-agent failure with a message suitable for a connection log.
final class SshAgentException implements Exception {
  final String message;
  final Object? cause;

  const SshAgentException(this.message, [this.cause]);

  @override
  String toString() => message;
}

/// Loads public identities and delegates signatures to the native ssh-agent.
///
/// Each request gets its own native connection. That keeps identity objects
/// stateless and lets several SSH handshakes use the same agent concurrently.
final class SshAgentClient {
  final SshAgentExchange _exchange;

  SshAgentClient({
    Map<String, String>? environment,
    @visibleForTesting Duration requestTimeout = _agentRequestTimeout,
  }) : _exchange = _nativeExchange(
         Map<String, String>.unmodifiable(environment ?? Platform.environment),
         requestTimeout,
       );

  @visibleForTesting
  SshAgentClient.withExchange(this._exchange);

  Future<List<SSHIdentity>> identities() async {
    final response = await _request(Uint8List.fromList([_requestIdentities]));
    final reader = _AgentReader(response);
    final type = reader.readByte('identity response type');
    if (type == _agentFailure) {
      throw const SshAgentException('The SSH agent refused to list its keys.');
    }
    if (type != _identitiesAnswer) {
      throw SshAgentException(
        'The SSH agent returned an unexpected identity response ($type).',
      );
    }

    final count = reader.readUint32('identity count');
    if (count > _maxAgentIdentities) {
      throw SshAgentException(
        'The SSH agent returned too many keys ($count; maximum '
        '$_maxAgentIdentities).',
      );
    }

    final identities = <SSHIdentity>[];
    for (var index = 0; index < count; index++) {
      final keyBlob = reader.readString('key ${index + 1}');
      final commentBytes = reader.readString('comment ${index + 1}');
      identities.add(
        _identity(keyBlob, utf8.decode(commentBytes, allowMalformed: true)),
      );
    }
    reader.requireDone('identity response');

    if (identities.isEmpty) {
      throw const SshAgentException(
        'The SSH agent has no keys loaded. Add a key to the agent and retry.',
      );
    }
    return List<SSHIdentity>.unmodifiable(identities);
  }

  SSHIdentity _identity(Uint8List keyBlob, String comment) {
    final publicKeyType = _publicKeyType(keyBlob);
    final authenticationType = switch (publicKeyType) {
      _rsaPublicKeyType => _rsaSha256Type,
      _rsaCertificateType => _rsaSha256CertificateType,
      _ => publicKeyType,
    };
    final signingFlags = switch (authenticationType) {
      _rsaSha256Type || _rsaSha256CertificateType => _rsaSha256Flag,
      _ => 0,
    };
    final immutableKeyBlob = Uint8List.fromList(keyBlob);

    return SSHIdentity.custom(
      type: authenticationType,
      publicKey: SSHRawHostKey(immutableKeyBlob),
      comment: comment,
      shouldProbe: true,
      signer: (data) => _sign(
        keyBlob: immutableKeyBlob,
        data: data,
        flags: signingFlags,
        expectedRsaType: signingFlags == 0 ? null : _rsaSha256Type,
      ),
    );
  }

  Future<SSHSignature> _sign({
    required Uint8List keyBlob,
    required Uint8List data,
    required int flags,
    required String? expectedRsaType,
  }) async {
    final writer = _AgentWriter()
      ..writeByte(_signRequest)
      ..writeString(keyBlob)
      ..writeString(data)
      ..writeUint32(flags);
    final response = await _request(writer.takeBytes());
    final reader = _AgentReader(response);
    final type = reader.readByte('signature response type');
    if (type == _agentFailure) {
      throw const SshAgentException(
        'The SSH agent refused to sign with this key.',
      );
    }
    if (type != _signResponse) {
      throw SshAgentException(
        'The SSH agent returned an unexpected signature response ($type).',
      );
    }

    final signatureBlob = reader.readString('signature');
    reader.requireDone('signature response');
    if (expectedRsaType != null) {
      final actualType = _signatureType(signatureBlob);
      if (actualType != expectedRsaType) {
        throw SshAgentException(
          'The SSH agent returned $actualType for an $expectedRsaType '
          'signature request.',
        );
      }
    }
    return SSHRawSignature(signatureBlob);
  }

  Future<Uint8List> _request(Uint8List payload) async {
    if (payload.length > _maxAgentMessageBytes) {
      throw const SshAgentException('The SSH agent request is too large.');
    }

    try {
      final response = await _exchange(_frame(payload));
      return _unframe(response);
    } on SshAgentException {
      rethrow;
    } catch (error) {
      throw SshAgentException(
        'Could not communicate with the SSH agent: '
        '$error',
        error,
      );
    }
  }
}

String _publicKeyType(Uint8List keyBlob) {
  try {
    return SSHHostKey.getType(keyBlob);
  } catch (error) {
    throw SshAgentException(
      'The SSH agent returned an invalid public key.',
      error,
    );
  }
}

String _signatureType(Uint8List signatureBlob) {
  try {
    return SSHSignature.getType(signatureBlob);
  } catch (error) {
    throw SshAgentException(
      'The SSH agent returned an invalid signature.',
      error,
    );
  }
}

SshAgentExchange _nativeExchange(
  Map<String, String> environment,
  Duration requestTimeout,
) {
  if (requestTimeout <= Duration.zero) {
    throw ArgumentError.value(
      requestTimeout,
      'requestTimeout',
      'must be positive',
    );
  }
  if (Platform.isWindows) {
    return (request) => _exchangeWithWindowsAgent(request, requestTimeout);
  }

  return (request) =>
      _exchangeWithUnixAgent(request, environment, requestTimeout);
}

Future<Uint8List> _exchangeWithUnixAgent(
  Uint8List request,
  Map<String, String> environment,
  Duration requestTimeout,
) async {
  final socketPath = environment[_agentSocketVariable]?.trim();
  if (socketPath == null || socketPath.isEmpty) {
    throw const SshAgentException(
      'No ssh-agent is available: SSH_AUTH_SOCK is not set.',
    );
  }

  Socket? socket;
  _StreamReader? reader;
  var timedOut = false;
  final timeoutTimer = Timer(requestTimeout, () {
    timedOut = true;
    socket?.destroy();
  });
  try {
    socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
      timeout: requestTimeout,
    );
    // Socket.connect can succeed just after our whole-request deadline fires.
    if (timedOut) {
      throw _agentTimeoutException('ssh-agent', requestTimeout);
    }

    reader = _StreamReader(socket);
    socket.add(request);
    await socket.flush();

    return await reader.readFrame();
  } on SshAgentException catch (error) {
    if (timedOut) {
      throw _agentTimeoutException('ssh-agent', requestTimeout, error);
    }
    rethrow;
  } catch (error) {
    if (timedOut || error is TimeoutException) {
      throw _agentTimeoutException('ssh-agent', requestTimeout, error);
    }
    throw SshAgentException(
      'Could not use the ssh-agent at SSH_AUTH_SOCK: $error',
      error,
    );
  } finally {
    timeoutTimer.cancel();
    try {
      await reader?.cancel();
    } catch (_) {
      // The deadline may already have destroyed the socket.
    }
    socket?.destroy();
  }
}

Future<Uint8List> _exchangeWithWindowsAgent(
  Uint8List request,
  Duration requestTimeout,
) async {
  try {
    return await Isolate.run(
      () =>
          _WindowsAgentPipe().exchange(request, requestTimeout: requestTimeout),
    );
  } on SshAgentException {
    rethrow;
  } catch (error) {
    throw SshAgentException(
      'Could not use the Windows ssh-agent at $_windowsAgentPipe: $error',
      error,
    );
  }
}

SshAgentException _agentTimeoutException(
  String agent,
  Duration timeout, [
  Object? cause,
]) => SshAgentException(
  'The $agent request timed out after ${timeout.inMilliseconds} ms.',
  cause,
);

final class _StreamReader {
  final StreamIterator<List<int>> _chunks;
  Uint8List _current = Uint8List(0);
  int _offset = 0;

  _StreamReader(Stream<List<int>> stream) : _chunks = StreamIterator(stream);

  Future<Uint8List> readFrame() async {
    final header = await _readExactly(_frameHeaderBytes);
    final payloadLength = _payloadLength(header);
    final payload = await _readExactly(payloadLength);
    return Uint8List.fromList([...header, ...payload]);
  }

  Future<Uint8List> _readExactly(int count) async {
    final result = Uint8List(count);
    var written = 0;
    while (written < count) {
      if (_offset == _current.length) {
        if (!await _chunks.moveNext()) {
          throw const SshAgentException(
            'The SSH agent closed its socket mid-response.',
          );
        }
        _current = Uint8List.fromList(_chunks.current);
        _offset = 0;
        if (_current.isEmpty) continue;
      }

      final available = _current.length - _offset;
      final copied = available < count - written ? available : count - written;
      result.setRange(written, written + copied, _current, _offset);
      written += copied;
      _offset += copied;
    }
    return result;
  }

  Future<void> cancel() => _chunks.cancel();
}

final class _WindowsAgentPipe {
  static const _genericRead = 0x80000000;
  static const _genericWrite = 0x40000000;
  static const _openExisting = 3;
  static const _securitySqosPresent = 0x00100000;
  static const _securityIdentification = 0x00010000;
  static const _fileFlagOverlapped = 0x40000000;
  static const _errorPipeBusy = 231;
  static const _errorIoPending = 997;
  static const _waitObject = 0;
  static const _waitTimeout = 258;
  static const _waitInfinite = 0xffffffff;

  final DynamicLibrary _kernel = DynamicLibrary.open('kernel32.dll');

  late final _CreateFileW _createFile = _kernel
      .lookupFunction<_CreateFileWNative, _CreateFileW>('CreateFileW');
  late final _ReadFile _readFile = _kernel
      .lookupFunction<_ReadFileNative, _ReadFile>('ReadFile');
  late final _WriteFile _writeFile = _kernel
      .lookupFunction<_WriteFileNative, _WriteFile>('WriteFile');
  late final _CloseHandle _closeHandle = _kernel
      .lookupFunction<_CloseHandleNative, _CloseHandle>('CloseHandle');
  late final _GetLastError _getLastError = _kernel
      .lookupFunction<_GetLastErrorNative, _GetLastError>('GetLastError');
  late final _WaitNamedPipeW _waitNamedPipe = _kernel
      .lookupFunction<_WaitNamedPipeWNative, _WaitNamedPipeW>('WaitNamedPipeW');
  late final _CreateEventW _createEvent = _kernel
      .lookupFunction<_CreateEventWNative, _CreateEventW>('CreateEventW');
  late final _WaitForSingleObject _waitForSingleObject = _kernel
      .lookupFunction<_WaitForSingleObjectNative, _WaitForSingleObject>(
        'WaitForSingleObject',
      );
  late final _GetOverlappedResult _getOverlappedResult = _kernel
      .lookupFunction<_GetOverlappedResultNative, _GetOverlappedResult>(
        'GetOverlappedResult',
      );
  late final _CancelIoEx _cancelIoEx = _kernel
      .lookupFunction<_CancelIoExNative, _CancelIoEx>('CancelIoEx');

  Uint8List exchange(Uint8List request, {required Duration requestTimeout}) {
    final pipeName = _windowsAgentPipe.toNativeUtf16();
    final elapsed = Stopwatch()..start();
    Pointer<Void> handle = nullptr;
    try {
      handle = _connect(pipeName, elapsed, requestTimeout);
      _writeExactly(handle, request, elapsed, requestTimeout);

      final header = _readExactly(
        handle,
        _frameHeaderBytes,
        elapsed,
        requestTimeout,
      );
      final payloadLength = _payloadLength(header);
      final payload = _readExactly(
        handle,
        payloadLength,
        elapsed,
        requestTimeout,
      );
      return Uint8List.fromList([...header, ...payload]);
    } finally {
      if (handle != nullptr) _closeHandle(handle);
      calloc.free(pipeName);
    }
  }

  Pointer<Void> _connect(
    Pointer<Utf16> pipeName,
    Stopwatch elapsed,
    Duration requestTimeout,
  ) {
    final connectBudget = requestTimeout < _windowsPipeConnectTimeout
        ? requestTimeout
        : _windowsPipeConnectTimeout;
    while (true) {
      final handle = _createFile(
        pipeName,
        _genericRead | _genericWrite,
        0,
        nullptr,
        _openExisting,
        _securitySqosPresent | _securityIdentification | _fileFlagOverlapped,
        nullptr,
      );
      if (handle.address != Pointer<Void>.fromAddress(-1).address) {
        return handle;
      }

      final error = _getLastError();
      if (error != _errorPipeBusy) {
        throw SshAgentException(
          'Could not open the Windows ssh-agent pipe (Windows error $error).',
        );
      }

      final remaining =
          connectBudget.inMilliseconds - elapsed.elapsedMilliseconds;
      if (remaining <= 0) {
        if (connectBudget == requestTimeout) {
          throw _agentTimeoutException('Windows ssh-agent', requestTimeout);
        }
        throw const SshAgentException(
          'The Windows ssh-agent pipe stayed busy for 15 seconds.',
        );
      }
      final wait = remaining < _windowsPipeRetryInterval.inMilliseconds
          ? remaining
          : _windowsPipeRetryInterval.inMilliseconds;
      _waitNamedPipe(pipeName, wait);
    }
  }

  void _writeExactly(
    Pointer<Void> handle,
    Uint8List bytes,
    Stopwatch elapsed,
    Duration requestTimeout,
  ) {
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final transferred = _transfer(
          _WindowsIoOperation.write,
          handle,
          (buffer + offset).cast(),
          bytes.length - offset,
          elapsed,
          requestTimeout,
        );
        if (transferred == 0) {
          throw SshAgentException(
            'Writing to the Windows ssh-agent failed '
            '(Windows error ${_getLastError()}).',
          );
        }
        offset += transferred;
      }
    } finally {
      calloc.free(buffer);
    }
  }

  Uint8List _readExactly(
    Pointer<Void> handle,
    int count,
    Stopwatch elapsed,
    Duration requestTimeout,
  ) {
    if (count == 0) return Uint8List(0);

    final buffer = calloc<Uint8>(count);
    try {
      var offset = 0;
      while (offset < count) {
        final transferred = _transfer(
          _WindowsIoOperation.read,
          handle,
          (buffer + offset).cast(),
          count - offset,
          elapsed,
          requestTimeout,
        );
        if (transferred == 0) {
          throw const SshAgentException(
            'The Windows ssh-agent closed the pipe mid-response.',
          );
        }
        offset += transferred;
      }
      return Uint8List.fromList(buffer.asTypedList(count));
    } finally {
      calloc.free(buffer);
    }
  }

  int _transfer(
    _WindowsIoOperation operation,
    Pointer<Void> handle,
    Pointer<Void> buffer,
    int count,
    Stopwatch elapsed,
    Duration requestTimeout,
  ) {
    final event = _createEvent(nullptr, 0, 0, nullptr);
    if (event == nullptr) {
      throw SshAgentException(
        'Could not create a Windows ssh-agent I/O event '
        '(Windows error ${_getLastError()}).',
      );
    }

    final overlapped = calloc<_WindowsOverlapped>();
    final transferred = calloc<Uint32>();
    overlapped.ref.event = event;
    try {
      final started = switch (operation) {
        _WindowsIoOperation.read => _readFile(
          handle,
          buffer,
          count,
          transferred,
          overlapped,
        ),
        _WindowsIoOperation.write => _writeFile(
          handle,
          buffer,
          count,
          transferred,
          overlapped,
        ),
      };
      if (started != 0) return transferred.value;

      final startError = _getLastError();
      if (startError != _errorIoPending) {
        throw SshAgentException(
          '${operation.label} the Windows ssh-agent failed '
          '(Windows error $startError).',
        );
      }

      final remaining =
          requestTimeout.inMilliseconds - elapsed.elapsedMilliseconds;
      if (remaining <= 0) {
        _cancelAndDrain(handle, overlapped, transferred);
        throw _agentTimeoutException('Windows ssh-agent', requestTimeout);
      }
      final waitResult = _waitForSingleObject(event, remaining);
      if (waitResult == _waitTimeout) {
        _cancelAndDrain(handle, overlapped, transferred);
        throw _agentTimeoutException('Windows ssh-agent', requestTimeout);
      }
      if (waitResult != _waitObject) {
        final waitError = _getLastError();
        _cancelAndDrain(handle, overlapped, transferred);
        throw SshAgentException(
          'Waiting for the Windows ssh-agent failed '
          '(Windows error $waitError).',
        );
      }
      if (_getOverlappedResult(handle, overlapped, transferred, 0) == 0) {
        throw SshAgentException(
          '${operation.label} the Windows ssh-agent failed '
          '(Windows error ${_getLastError()}).',
        );
      }
      return transferred.value;
    } finally {
      calloc.free(transferred);
      calloc.free(overlapped);
      _closeHandle(event);
    }
  }

  void _cancelAndDrain(
    Pointer<Void> handle,
    Pointer<_WindowsOverlapped> overlapped,
    Pointer<Uint32> transferred,
  ) {
    _cancelIoEx(handle, overlapped);
    _waitForSingleObject(overlapped.ref.event, _waitInfinite);
    _getOverlappedResult(handle, overlapped, transferred, 0);
  }
}

enum _WindowsIoOperation {
  read('Reading from'),
  write('Writing to');

  final String label;

  const _WindowsIoOperation(this.label);
}

final class _WindowsOverlapped extends Struct {
  @IntPtr()
  external int internal;

  @IntPtr()
  external int internalHigh;

  @Uint32()
  external int offset;

  @Uint32()
  external int offsetHigh;

  external Pointer<Void> event;
}

typedef _CreateFileWNative =
    Pointer<Void> Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      Pointer<Void>,
    );
typedef _CreateFileW =
    Pointer<Void> Function(
      Pointer<Utf16>,
      int,
      int,
      Pointer<Void>,
      int,
      int,
      Pointer<Void>,
    );
typedef _ReadFileNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<Uint32>,
      Pointer<_WindowsOverlapped>,
    );
typedef _ReadFile =
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<Uint32>,
      Pointer<_WindowsOverlapped>,
    );
typedef _WriteFileNative = _ReadFileNative;
typedef _WriteFile = _ReadFile;
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandle = int Function(Pointer<Void>);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastError = int Function();
typedef _WaitNamedPipeWNative = Int32 Function(Pointer<Utf16>, Uint32);
typedef _WaitNamedPipeW = int Function(Pointer<Utf16>, int);
typedef _CreateEventWNative =
    Pointer<Void> Function(Pointer<Void>, Int32, Int32, Pointer<Utf16>);
typedef _CreateEventW =
    Pointer<Void> Function(Pointer<Void>, int, int, Pointer<Utf16>);
typedef _WaitForSingleObjectNative = Uint32 Function(Pointer<Void>, Uint32);
typedef _WaitForSingleObject = int Function(Pointer<Void>, int);
typedef _GetOverlappedResultNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<_WindowsOverlapped>,
      Pointer<Uint32>,
      Int32,
    );
typedef _GetOverlappedResult =
    int Function(
      Pointer<Void>,
      Pointer<_WindowsOverlapped>,
      Pointer<Uint32>,
      int,
    );
typedef _CancelIoExNative =
    Int32 Function(Pointer<Void>, Pointer<_WindowsOverlapped>);
typedef _CancelIoEx = int Function(Pointer<Void>, Pointer<_WindowsOverlapped>);

Uint8List _frame(Uint8List payload) {
  final writer = _AgentWriter()
    ..writeUint32(payload.length)
    ..writeBytes(payload);
  return writer.takeBytes();
}

Uint8List _unframe(Uint8List frame) {
  if (frame.length < _frameHeaderBytes) {
    throw const SshAgentException(
      'The SSH agent returned a truncated response frame.',
    );
  }
  final payloadLength = _payloadLength(
    Uint8List.sublistView(frame, 0, _frameHeaderBytes),
  );
  if (frame.length != _frameHeaderBytes + payloadLength) {
    throw const SshAgentException(
      'The SSH agent returned a malformed response frame.',
    );
  }
  return Uint8List.sublistView(frame, _frameHeaderBytes);
}

int _payloadLength(Uint8List header) {
  final length = ByteData.sublistView(header).getUint32(0);
  if (length > _maxAgentMessageBytes) {
    throw SshAgentException(
      'The SSH agent response is too large ($length bytes; maximum '
      '$_maxAgentMessageBytes).',
    );
  }
  return length;
}

final class _AgentWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void writeByte(int value) => _bytes.addByte(value);

  void writeBytes(List<int> value) => _bytes.add(value);

  void writeUint32(int value) {
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setUint32(0, value);
    _bytes.add(bytes);
  }

  void writeString(List<int> value) {
    writeUint32(value.length);
    writeBytes(value);
  }

  Uint8List takeBytes() => _bytes.takeBytes();
}

final class _AgentReader {
  final Uint8List _bytes;
  int _offset = 0;

  _AgentReader(this._bytes);

  int readByte(String field) {
    _require(1, field);
    return _bytes[_offset++];
  }

  int readUint32(String field) {
    _require(4, field);
    final result = ByteData.sublistView(_bytes).getUint32(_offset);
    _offset += 4;
    return result;
  }

  Uint8List readString(String field) {
    final length = readUint32('$field length');
    _require(length, field);
    final result = Uint8List.fromList(
      Uint8List.sublistView(_bytes, _offset, _offset + length),
    );
    _offset += length;
    return result;
  }

  void requireDone(String message) {
    if (_offset == _bytes.length) return;
    throw SshAgentException(
      'The SSH agent returned trailing bytes in its $message.',
    );
  }

  void _require(int count, String field) {
    if (count >= 0 && _offset <= _bytes.length - count) return;
    throw SshAgentException('The SSH agent returned a truncated $field.');
  }
}

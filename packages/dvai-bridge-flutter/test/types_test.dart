// Round-trip tests for the public Dart types vs the Pigeon wire shapes.

import 'package:dvai_bridge/dvai_bridge.dart';
import 'package:dvai_bridge/src/messages.g.dart' as wire;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BackendKind wire round-trip', () {
    test('every value round-trips through wireValue / fromWire', () {
      for (final BackendKind kind in BackendKind.values) {
        expect(BackendKind.fromWire(kind.wireValue), kind);
      }
    });

    test('unknown wire string returns null', () {
      expect(BackendKind.fromWire('mystery'), isNull);
    });
  });

  group('StartOptions.toMessage', () {
    test('encodes backend wire string + nullable scalars', () {
      const StartOptions opts = StartOptions(
        backend: BackendKind.llama,
        modelPath: '/m.gguf',
        contextSize: 4096,
        threads: 8,
        temperature: 0.5,
        embeddingMode: true,
        autoUnloadOnLowMemory: true,
        logLevel: LogLevel.debug,
      );

      final wire.StartOptionsMessage msg = opts.toMessage();
      expect(msg.backend, 'llama');
      expect(msg.modelPath, '/m.gguf');
      expect(msg.contextSize, 4096);
      expect(msg.threads, 8);
      expect(msg.temperature, 0.5);
      expect(msg.embeddingMode, isTrue);
      expect(msg.autoUnloadOnLowMemory, isTrue);
      expect(msg.logLevel, 'debug');
    });

    test('CorsOrigin variants encode to the agreed wire format', () {
      const StartOptions wildcard = StartOptions(
        backend: BackendKind.llama,
        corsOrigin: CorsOrigin.any(),
      );
      expect(wildcard.toMessage().corsOrigin, '*');

      const StartOptions exact = StartOptions(
        backend: BackendKind.llama,
        corsOrigin: CorsOrigin.exact('https://app.example'),
      );
      expect(exact.toMessage().corsOrigin, 'https://app.example');

      const StartOptions list = StartOptions(
        backend: BackendKind.llama,
        corsOrigin:
            CorsOrigin.list(<String>['https://a.example', 'https://b.example']),
      );
      expect(list.toMessage().corsOrigin,
          'https://a.example,https://b.example');
    });
  });

  group('BoundServer / StatusInfo / DownloadResult — fromMessage', () {
    test('BoundServer.fromMessage maps backend wire string', () {
      final BoundServer s = BoundServer.fromMessage(
        wire.BoundServerMessage(
          baseUrl: 'http://127.0.0.1:1/v1',
          port: 1,
          backend: 'mediapipe',
          modelId: 'm',
        ),
      );
      expect(s.backend, BackendKind.mediapipe);
      expect(s.port, 1);
    });

    test('StatusInfo.fromMessage handles the not-running case', () {
      final StatusInfo info = StatusInfo.fromMessage(
        wire.StatusInfoMessage(running: false),
      );
      expect(info.running, isFalse);
      expect(info.backend, isNull);
      expect(info.baseUrl, isNull);
    });

    test('DownloadResult.fromMessage preserves cached flag', () {
      final DownloadResult r = DownloadResult.fromMessage(
        wire.DownloadResultMessage(
          path: '/tmp/x',
          sha256: 'abc',
          sizeBytes: 7,
          cached: true,
        ),
      );
      expect(r.cached, isTrue);
      expect(r.sizeBytes, 7);
    });
  });

  group('DownloadOptions — header flattening', () {
    test('headers are encoded as alternating key/value pairs', () {
      const DownloadOptions opts = DownloadOptions(
        url: 'https://x',
        sha256: 'a',
        headers: <String, String>{'k': 'v', 'k2': 'v2'},
      );
      final wire.DownloadOptionsMessage msg = opts.toMessage();
      expect(msg.headers, isNotNull);
      expect(msg.headers!.length, 4);
      expect(msg.headers, contains('k'));
      expect(msg.headers, contains('v'));
      expect(msg.headers, contains('k2'));
      expect(msg.headers, contains('v2'));
    });

    test('null headers map encodes as null on the wire', () {
      const DownloadOptions opts = DownloadOptions(url: 'x', sha256: 'a');
      expect(opts.toMessage().headers, isNull);
    });
  });

  group('ProgressEvent.fromMessage', () {
    test('decodes kind / phase / errorKind', () {
      final ProgressEvent e = ProgressEvent.fromMessage(
        wire.ProgressEventMessage(
          kind: 'failed',
          phase: 'start',
          errorKind: 'modelLoadFailed',
          errorMessage: 'corrupt file',
        ),
      );
      expect(e.kind, ProgressKind.failed);
      expect(e.phase, ProgressPhase.start);
      expect(e.errorKind, DVAIBridgeErrorKind.modelLoadFailed);
      expect(e.errorMessage, 'corrupt file');
    });

    test('falls back gracefully on unknown wire strings', () {
      final ProgressEvent e = ProgressEvent.fromMessage(
        wire.ProgressEventMessage(kind: 'unknown', phase: 'unknown'),
      );
      // The defaults shouldn't crash — they're chosen to be benign.
      expect(e.kind, ProgressKind.progress);
      expect(e.phase, ProgressPhase.error);
    });
  });
}

// Unit tests for the DVAIBridge Dart facade. Covers:
//
//   - Cross-platform validation rejecting iOS-only / Android-only backends.
//   - Happy-path BoundServer round-trip.
//   - PlatformException → DVAIBridgeError translation.
//   - downloadModel() round-trip.

import 'package:dvai_bridge/dvai_bridge.dart';
import 'package:dvai_bridge/src/messages.g.dart' as wire;
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DVAIBridge.start — backend availability', () {
    test('rejects MediaPipe on iOS', () async {
      final FakeHostApi api = FakeHostApi();
      final FakeProgressEventChannel events = FakeProgressEventChannel();
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: events,
        platform: const FakePlatform.ios(),
      );

      await expectLater(
        bridge.start(const StartOptions(backend: BackendKind.mediapipe)),
        throwsA(isA<BackendUnavailableError>().having(
          (BackendUnavailableError err) => err.backend,
          'backend',
          BackendKind.mediapipe,
        )),
      );
      expect(api.startCalls, isEmpty,
          reason: 'Dart-side guard runs before crossing the channel');
    });

    test('rejects LiteRT on iOS', () async {
      final FakeHostApi api = FakeHostApi();
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.ios(),
      );

      await expectLater(
        bridge.start(const StartOptions(backend: BackendKind.litert)),
        throwsA(isA<BackendUnavailableError>()),
      );
    });

    test('rejects Foundation on Android', () async {
      final FakeHostApi api = FakeHostApi();
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.android(),
      );

      await expectLater(
        bridge.start(const StartOptions(backend: BackendKind.foundation)),
        throwsA(isA<BackendUnavailableError>()),
      );
    });

    test('rejects MLX on Android', () async {
      final FakeHostApi api = FakeHostApi();
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.android(),
      );

      await expectLater(
        bridge.start(const StartOptions(backend: BackendKind.mlx)),
        throwsA(isA<BackendUnavailableError>()),
      );
    });

    test('rejects all backends on unsupported platforms', () async {
      final DVAIBridge bridge = DVAIBridge.test(
        api: FakeHostApi(),
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.unsupported(),
      );

      await expectLater(
        bridge.start(const StartOptions(backend: BackendKind.auto)),
        throwsA(isA<BackendUnavailableError>()),
      );
    });
  });

  group('DVAIBridge.start — happy path', () {
    test('forwards opts and resolves a BoundServer', () async {
      final FakeHostApi api = FakeHostApi();
      api.onStart = (wire.StartOptionsMessage opts) async {
        return wire.BoundServerMessage(
          baseUrl: 'http://127.0.0.1:38883/v1',
          port: 38883,
          backend: 'llama',
          modelId: 'tinyllama',
        );
      };
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.android(),
      );

      final BoundServer server = await bridge.start(const StartOptions(
        backend: BackendKind.auto,
        modelPath: '/tmp/tinyllama.gguf',
        contextSize: 1024,
      ));

      expect(server.baseUrl, 'http://127.0.0.1:38883/v1');
      expect(server.port, 38883);
      expect(server.backend, BackendKind.llama);
      expect(server.modelId, 'tinyllama');

      expect(api.startCalls, hasLength(1));
      expect(api.startCalls.single.backend, 'auto');
      expect(api.startCalls.single.modelPath, '/tmp/tinyllama.gguf');
      expect(api.startCalls.single.contextSize, 1024);
    });
  });

  group('DVAIBridge — PlatformException translation', () {
    test('alreadyStarted carries backend + baseUrl from details', () async {
      final FakeHostApi api = FakeHostApi();
      api.onStart = (wire.StartOptionsMessage opts) async {
        throw makePlatformException(
          code: 'alreadyStarted',
          message: 'already running',
          details: <String, Object?>{
            'backend': 'llama',
            'baseUrl': 'http://127.0.0.1:38883/v1',
          },
        );
      };
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.android(),
      );

      try {
        await bridge.start(const StartOptions(backend: BackendKind.llama));
        fail('expected DVAIBridgeError');
      } on AlreadyStartedError catch (err) {
        expect(err.kind, DVAIBridgeErrorKind.alreadyStarted);
        expect(err.backend, BackendKind.llama);
        expect(err.baseUrl, 'http://127.0.0.1:38883/v1');
      }
    });

    test('configurationInvalid maps to ConfigurationInvalidError', () async {
      final FakeHostApi api = FakeHostApi();
      api.onStart = (wire.StartOptionsMessage opts) async {
        throw makePlatformException(
          code: 'configurationInvalid',
          message: 'modelPath is required',
        );
      };
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.android(),
      );

      try {
        await bridge.start(const StartOptions(backend: BackendKind.llama));
        fail('expected DVAIBridgeError');
      } on ConfigurationInvalidError catch (err) {
        expect(err.kind, DVAIBridgeErrorKind.configurationInvalid);
        expect(err.message, 'modelPath is required');
      }
    });

    test('unknown code falls through to backendError', () async {
      final FakeHostApi api = FakeHostApi();
      api.onStop = () async {
        throw makePlatformException(code: 'someUnknownCode', message: 'oops');
      };
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.ios(),
      );

      try {
        await bridge.stop();
        fail('expected DVAIBridgeError');
      } on BackendErrorError catch (err) {
        expect(err.kind, DVAIBridgeErrorKind.backendError);
        expect(err.message, 'oops');
      }
    });
  });

  group('DVAIBridge.stop / status / downloadModel', () {
    test('stop() forwards to native and resolves void', () async {
      final FakeHostApi api = FakeHostApi();
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.ios(),
      );
      await bridge.stop();
      expect(api.stopCalls, 1);
    });

    test('status() decodes a running info', () async {
      final FakeHostApi api = FakeHostApi();
      api.onStatus = () async => wire.StatusInfoMessage(
            running: true,
            baseUrl: 'http://127.0.0.1:42424/v1',
            port: 42424,
            backend: 'llama',
            modelId: 'tiny',
          );
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.android(),
      );
      final StatusInfo info = await bridge.status();
      expect(info.running, isTrue);
      expect(info.baseUrl, 'http://127.0.0.1:42424/v1');
      expect(info.backend, BackendKind.llama);
    });

    test('downloadModel() forwards opts + headers and decodes the result',
        () async {
      final FakeHostApi api = FakeHostApi();
      api.onDownload = (wire.DownloadOptionsMessage opts) async {
        return wire.DownloadResultMessage(
          path: '/tmp/cached.gguf',
          sha256: opts.sha256,
          sizeBytes: 4096,
          cached: true,
        );
      };
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.android(),
      );

      final DownloadResult result = await bridge.downloadModel(
        const DownloadOptions(
          url: 'https://example.com/m.gguf',
          sha256: 'abc123',
          headers: <String, String>{
            'Authorization': 'Bearer token',
            'X-Test': '1',
          },
        ),
      );

      expect(result.path, '/tmp/cached.gguf');
      expect(result.sha256, 'abc123');
      expect(result.sizeBytes, 4096);
      expect(result.cached, isTrue);

      expect(api.downloadCalls, hasLength(1));
      final wire.DownloadOptionsMessage sent = api.downloadCalls.single;
      expect(sent.url, 'https://example.com/m.gguf');
      expect(sent.headers, contains('Authorization'));
      expect(sent.headers, contains('Bearer token'));
    });
  });
}

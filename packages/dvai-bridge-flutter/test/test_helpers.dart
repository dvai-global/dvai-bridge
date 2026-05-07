// Test helpers shared across the dvai_bridge unit-test suite. Lives in
// the test directory so they don't leak into the published package.

import 'dart:async';

import 'package:dvai_bridge/src/dvai_bridge.dart';
import 'package:dvai_bridge/src/messages.g.dart' as wire;
import 'package:flutter/services.dart' show PlatformException;

/// Hand-written stub of [wire.DVAIBridgeHostApi] that lets tests script the
/// responses returned to the Dart facade. Avoids the build_runner / mockito
/// generation step (the four methods are simple enough to roll by hand).
class FakeHostApi extends wire.DVAIBridgeHostApi {
  FakeHostApi();

  Future<wire.BoundServerMessage> Function(wire.StartOptionsMessage opts)?
      onStart;
  Future<void> Function()? onStop;
  Future<wire.StatusInfoMessage> Function()? onStatus;
  Future<wire.DownloadResultMessage> Function(wire.DownloadOptionsMessage opts)?
      onDownload;
  Future<void> Function(String requestId, bool approved)? onRespondToPairing;

  /// Calls captured for assertion convenience.
  final List<wire.StartOptionsMessage> startCalls =
      <wire.StartOptionsMessage>[];
  int stopCalls = 0;
  int statusCalls = 0;
  final List<wire.DownloadOptionsMessage> downloadCalls =
      <wire.DownloadOptionsMessage>[];
  final List<({String requestId, bool approved})> respondToPairingCalls =
      <({String requestId, bool approved})>[];

  @override
  Future<wire.BoundServerMessage> startBridge(
      wire.StartOptionsMessage opts) async {
    startCalls.add(opts);
    final Future<wire.BoundServerMessage> Function(wire.StartOptionsMessage)?
        handler = onStart;
    if (handler != null) {
      return handler(opts);
    }
    return wire.BoundServerMessage(
      baseUrl: 'http://127.0.0.1:38883/v1',
      port: 38883,
      backend: opts.backend,
      modelId: 'test-model',
    );
  }

  @override
  Future<void> stopBridge() async {
    stopCalls += 1;
    final Future<void> Function()? handler = onStop;
    if (handler != null) {
      await handler();
    }
  }

  @override
  Future<wire.StatusInfoMessage> status() async {
    statusCalls += 1;
    final Future<wire.StatusInfoMessage> Function()? handler = onStatus;
    if (handler != null) {
      return handler();
    }
    return wire.StatusInfoMessage(running: false);
  }

  @override
  Future<wire.DownloadResultMessage> downloadModel(
      wire.DownloadOptionsMessage opts) async {
    downloadCalls.add(opts);
    final Future<wire.DownloadResultMessage> Function(
            wire.DownloadOptionsMessage)?
        handler = onDownload;
    if (handler != null) {
      return handler(opts);
    }
    return wire.DownloadResultMessage(
      path: '/tmp/test-model.gguf',
      sha256: opts.sha256,
      sizeBytes: 1024,
      cached: false,
    );
  }

  @override
  Future<void> respondToPairingRequest(String requestId, bool approved) async {
    respondToPairingCalls
        .add((requestId: requestId, approved: approved));
    final Future<void> Function(String, bool)? handler = onRespondToPairing;
    if (handler != null) {
      await handler(requestId, approved);
    }
  }
}

/// In-memory implementation of [ProgressEventChannel] for tests.
class FakeProgressEventChannel implements ProgressEventChannel {
  FakeProgressEventChannel();

  final StreamController<wire.ProgressEventMessage> _controller =
      StreamController<wire.ProgressEventMessage>.broadcast();

  @override
  Stream<wire.ProgressEventMessage> events() => _controller.stream;

  /// Push an event onto the simulated platform stream.
  void emit(wire.ProgressEventMessage event) {
    _controller.add(event);
  }

  /// Close the underlying controller; subsequent listeners receive a
  /// closed stream.
  Future<void> close() => _controller.close();
}

/// In-memory implementation of [PairingRequestEventChannel] for tests.
class FakePairingRequestEventChannel implements PairingRequestEventChannel {
  FakePairingRequestEventChannel();

  final StreamController<wire.PairingRequestMessage> _controller =
      StreamController<wire.PairingRequestMessage>.broadcast();

  @override
  Stream<wire.PairingRequestMessage> events() => _controller.stream;

  /// Push a pairing request onto the simulated platform stream.
  void emit(wire.PairingRequestMessage event) {
    _controller.add(event);
  }

  /// Close the underlying controller; subsequent listeners receive a
  /// closed stream.
  Future<void> close() => _controller.close();
}

/// Test-only [PlatformAdapter] implementations.
class FakePlatform implements PlatformAdapter {
  const FakePlatform.ios()
      : isIOS = true,
        isAndroid = false;

  const FakePlatform.android()
      : isIOS = false,
        isAndroid = true;

  const FakePlatform.unsupported()
      : isIOS = false,
        isAndroid = false;

  @override
  final bool isIOS;
  @override
  final bool isAndroid;
}

/// Construct a `PlatformException` shaped like a real Pigeon failure.
PlatformException makePlatformException({
  required String code,
  String? message,
  Object? details,
}) {
  return PlatformException(code: code, message: message, details: details);
}

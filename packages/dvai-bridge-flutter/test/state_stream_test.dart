// Tests for the derived `Stream<DVAIBridgeState>` view exposed by
// DVAIBridge.instance.stateStream. Verifies that progress events drive
// state transitions correctly.

import 'dart:async';

import 'package:dvai_bridge/dvai_bridge.dart';
import 'package:dvai_bridge/src/messages.g.dart' as wire;
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stateStream emits an initial state on first listen, then transitions',
      () async {
    final FakeHostApi api = FakeHostApi();
    final FakeProgressEventChannel events = FakeProgressEventChannel();
    bool started = false;
    api.onStatus = () async {
      if (!started) {
        return wire.StatusInfoMessage(running: false);
      }
      return wire.StatusInfoMessage(
        running: true,
        baseUrl: 'http://127.0.0.1:38883/v1',
        port: 38883,
        backend: 'llama',
        modelId: 'tiny',
      );
    };

    final DVAIBridge bridge = DVAIBridge.test(
      api: api,
      eventChannel: events,
      platform: const FakePlatform.android(),
    );
    addTearDown(bridge.dispose);

    final Completer<List<DVAIBridgeState>> doneCompleter =
        Completer<List<DVAIBridgeState>>();
    final List<DVAIBridgeState> received = <DVAIBridgeState>[];
    final StreamSubscription<DVAIBridgeState> sub =
        bridge.stateStream.listen((DVAIBridgeState state) {
      received.add(state);
      if (state.isReady && !doneCompleter.isCompleted) {
        doneCompleter.complete(List<DVAIBridgeState>.from(received));
      }
    });
    addTearDown(sub.cancel);

    // Allow the first-listener bootstrap to fire (it calls status()).
    await Future<void>.delayed(Duration.zero);

    started = true;
    events.emit(wire.ProgressEventMessage(kind: 'started', phase: 'start'));
    events.emit(wire.ProgressEventMessage(kind: 'completed', phase: 'start'));

    final List<DVAIBridgeState> states = await doneCompleter.future
        .timeout(const Duration(seconds: 2));

    expect(states, isNotEmpty);
    final DVAIBridgeState last = states.last;
    expect(last.isReady, isTrue);
    expect(last.baseUrl, 'http://127.0.0.1:38883/v1');
    expect(last.port, 38883);
    expect(last.backend, BackendKind.llama);
  });

  test('stateStream emits idle on completed-stop', () async {
    final FakeHostApi api = FakeHostApi();
    api.onStatus = () async => wire.StatusInfoMessage(running: false);
    final FakeProgressEventChannel events = FakeProgressEventChannel();
    final DVAIBridge bridge = DVAIBridge.test(
      api: api,
      eventChannel: events,
      platform: const FakePlatform.android(),
    );
    addTearDown(bridge.dispose);

    final List<DVAIBridgeState> received = <DVAIBridgeState>[];
    final StreamSubscription<DVAIBridgeState> sub =
        bridge.stateStream.listen(received.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);

    events.emit(wire.ProgressEventMessage(kind: 'completed', phase: 'stop'));
    await Future<void>.delayed(Duration.zero);

    expect(received.last.isReady, isFalse);
    expect(received.last.lastProgress, isNotNull);
    expect(received.last.lastProgress!.phase, ProgressPhase.stop);
  });

  test('stateStream surfaces failed-start as a lastError', () async {
    final FakeHostApi api = FakeHostApi();
    api.onStatus = () async => wire.StatusInfoMessage(running: false);
    final FakeProgressEventChannel events = FakeProgressEventChannel();
    final DVAIBridge bridge = DVAIBridge.test(
      api: api,
      eventChannel: events,
      platform: const FakePlatform.android(),
    );
    addTearDown(bridge.dispose);

    final List<DVAIBridgeState> received = <DVAIBridgeState>[];
    final StreamSubscription<DVAIBridgeState> sub =
        bridge.stateStream.listen(received.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);

    events.emit(wire.ProgressEventMessage(
      kind: 'failed',
      phase: 'start',
      errorKind: 'modelLoadFailed',
      errorMessage: 'corrupt file',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(received.last.isReady, isFalse);
    expect(received.last.lastError, isNotNull);
    expect(received.last.lastError!.message, 'corrupt file');
  });
}

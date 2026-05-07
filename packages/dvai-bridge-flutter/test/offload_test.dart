// Unit tests for the v3.0+ distributed-inference / offload surface on
// the Dart facade. Covers:
//
//   - StartOptions.offload round-trips through the Pigeon wire format.
//   - DVAIBridge.pairingRequests yields decoded PairingRequest values.
//   - PairingRequest.respond forwards through to respondToPairingRequest.
//   - DVAIBridge.respondToPairingRequest forwards (id, approved) to host.

import 'package:dvai_bridge/dvai_bridge.dart';
import 'package:dvai_bridge/src/messages.g.dart' as wire;
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StartOptions.offload', () {
    test('serializes through to the Pigeon StartOptionsMessage', () async {
      final FakeHostApi api = FakeHostApi();
      final FakePairingRequestEventChannel pairingEvents =
          FakePairingRequestEventChannel();
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        pairingEventChannel: pairingEvents,
        platform: const FakePlatform.ios(),
      );

      const OffloadConfig offload = OffloadConfig(
        enabled: true,
        discoverLAN: true,
        minLocalCapability: 12,
        rendezvousUrl: 'wss://rendezvous.myapp.com',
        knownPeers: <Peer>[
          Peer(
            deviceId: 'peer-1',
            deviceName: 'Studio Mac',
            dvaiVersion: '3.0.0',
            baseUrl: 'http://192.168.1.42:38883/v1',
            loadedModels: <String>['Llama-3.2-1B-Instruct.Q4_K_M'],
            capability: <String, double>{
              'Llama-3.2-1B-Instruct.Q4_K_M': 32.0,
            },
            via: PeerVia.static_,
            secure: false,
            lastSeenAt: 1700000000000,
          ),
        ],
      );

      await bridge.start(const StartOptions(
        backend: BackendKind.auto,
        modelPath: '/tmp/m.gguf',
        offload: offload,
      ));

      expect(api.startCalls, hasLength(1));
      final wire.StartOptionsMessage opts = api.startCalls.single;
      expect(opts.offload, isNotNull);
      expect(opts.offload!.enabled, isTrue);
      expect(opts.offload!.discoverLAN, isTrue);
      expect(opts.offload!.minLocalCapability, 12.0);
      expect(opts.offload!.rendezvousUrl, 'wss://rendezvous.myapp.com');
      expect(opts.offload!.knownPeers, hasLength(1));
      final wire.PeerMessage peerMsg = opts.offload!.knownPeers!.first;
      expect(peerMsg.deviceId, 'peer-1');
      expect(peerMsg.via, 'static');
      expect(peerMsg.loadedModels, <String>['Llama-3.2-1B-Instruct.Q4_K_M']);
      // Capability: alternating-pair encoding [k1, v1, k2, v2, ...].
      expect(peerMsg.capability, <Object?>[
        'Llama-3.2-1B-Instruct.Q4_K_M',
        32.0,
      ]);
    });

    test('omitting offload leaves the wire-format field null', () async {
      final FakeHostApi api = FakeHostApi();
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.ios(),
      );

      await bridge.start(const StartOptions(
        backend: BackendKind.auto,
        modelPath: '/tmp/m.gguf',
      ));

      expect(api.startCalls, hasLength(1));
      expect(api.startCalls.single.offload, isNull);
    });
  });

  group('DVAIBridge.pairingRequests', () {
    test(
        'decodes Pigeon PairingRequestMessage events into PairingRequest values',
        () async {
      final FakeHostApi api = FakeHostApi();
      final FakePairingRequestEventChannel pairingEvents =
          FakePairingRequestEventChannel();
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        pairingEventChannel: pairingEvents,
        platform: const FakePlatform.ios(),
      );

      final List<PairingRequest> received = <PairingRequest>[];
      final subscription = bridge.pairingRequests.listen(received.add);

      pairingEvents.emit(wire.PairingRequestMessage(
        id: 'req-abc',
        peer: wire.PeerMessage(
          deviceId: 'peer-2',
          deviceName: 'Living Room iPad',
          dvaiVersion: '3.0.0',
          baseUrl: 'http://192.168.1.43:38883/v1',
          loadedModels: <String>[],
          capability: <Object?>[],
          via: 'mdns',
          secure: false,
          lastSeenAt: 1700000000000,
        ),
        expiresAt: 1700000060000,
      ));

      // Yield to the event loop so the broadcast stream delivers.
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      final PairingRequest req = received.first;
      expect(req.id, 'req-abc');
      expect(req.peerDeviceName, 'Living Room iPad');
      expect(req.peer.via, PeerVia.mdns);
      expect(req.expiresAt, 1700000060000);

      // PairingRequest.respond delegates to respondToPairingRequest.
      await req.respond(approved: true);
      expect(api.respondToPairingCalls, hasLength(1));
      expect(api.respondToPairingCalls.single,
          (requestId: 'req-abc', approved: true));

      await subscription.cancel();
    });
  });

  group('DVAIBridge.respondToPairingRequest', () {
    test('forwards (requestId, approved) to the host API', () async {
      final FakeHostApi api = FakeHostApi();
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.ios(),
      );

      await bridge.respondToPairingRequest('req-xyz', false);

      expect(api.respondToPairingCalls, hasLength(1));
      expect(api.respondToPairingCalls.single,
          (requestId: 'req-xyz', approved: false));
    });

    test('translates PlatformException → DVAIBridgeError', () async {
      final FakeHostApi api = FakeHostApi();
      api.onRespondToPairing =
          (String requestId, bool approved) => Future<void>.error(
                makePlatformException(
                  code: 'configurationInvalid',
                  message: 'unknown pairing id',
                ),
              );
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.ios(),
      );

      await expectLater(
        bridge.respondToPairingRequest('nope', true),
        throwsA(isA<ConfigurationInvalidError>()),
      );
    });
  });

  group('OffloadConfig value semantics', () {
    test('OffloadConfig.copyWith replaces individual fields', () {
      const OffloadConfig base = OffloadConfig(
        enabled: false,
        minLocalCapability: 10,
      );
      final OffloadConfig updated = base.copyWith(
        enabled: true,
        rendezvousUrl: 'wss://x.example.com',
      );
      expect(updated.enabled, isTrue);
      expect(updated.minLocalCapability, 10.0);
      expect(updated.rendezvousUrl, 'wss://x.example.com');
    });

    test('Two equal OffloadConfigs compare equal', () {
      const OffloadConfig a = OffloadConfig(enabled: true);
      const OffloadConfig b = OffloadConfig(enabled: true);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('PeerVia round-trips through the wire format', () {
      for (final PeerVia via in PeerVia.values) {
        expect(PeerVia.fromWire(via.wireValue), via);
      }
      expect(PeerVia.fromWire('not-a-thing'), isNull);
    });
  });
}

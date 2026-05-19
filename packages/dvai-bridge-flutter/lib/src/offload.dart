// Public Dart types for v3.0+ distributed-inference / device-offload
// support. Mirrors the `OffloadConfig` shape of `@dvai-bridge/core` and
// the iOS `OffloadConfig` / Android `OffloadConfig` 1:1, with the
// constraint that function-typed callbacks can't cross the Pigeon
// channel — those are surfaced as the `pairingRequests` Stream on
// [DVAIBridge].

import 'package:meta/meta.dart';

import 'messages.g.dart' as wire;

/// Distributed-inference configuration. Pass to [StartOptions.offload]
/// to enable peer-to-peer offload of inference requests when the local
/// device's hardware can't serve the model fast enough.
///
/// See the [distributed-inference guide](https://bridge.deepvoiceai.co/guide/distributed-inference)
/// for the full feature description.
///
/// Pairing-request UI is surfaced via [DVAIBridge.pairingRequests] —
/// the function-typed `onPairingRequest` / `onOffload` callbacks of the
/// JS-side `OffloadConfig` aren't representable across the Pigeon
/// channel, so Dart consumers listen to a [Stream] of [PairingRequest]
/// values and call [PairingRequest.respond] to record the user's
/// decision.
@immutable
class OffloadConfig {
  /// Construct an [OffloadConfig]. Only [enabled] is required; the rest
  /// fall back to platform defaults documented in the
  /// [distributed-inference guide](https://bridge.deepvoiceai.co/guide/distributed-inference).
  const OffloadConfig({
    required this.enabled,
    this.discoverLAN,
    this.minLocalCapability,
    this.rendezvousUrl,
    this.knownPeers,
  });

  /// Master switch. Default: false; offload is opt-in at v3.0.
  final bool enabled;

  /// Run mDNS / Bonjour to discover LAN peers. Default: true when
  /// [enabled] is true.
  final bool? discoverLAN;

  /// Below this tok/s, look for a peer. Default: 10.
  final double? minLocalCapability;

  /// Optional rendezvous-server URL — enables the internet path when
  /// set. See the
  /// [self-hosting guide](https://bridge.deepvoiceai.co/guide/self-hosting-rendezvous)
  /// for deployment options.
  final String? rendezvousUrl;

  /// Optional pre-known peers — useful when the consumer app already
  /// has a device registry (corporate fleet, persisted pairings).
  /// Combined with mDNS / rendezvous discovery on the native side.
  final List<Peer>? knownPeers;

  /// Returns a copy of this config with the given fields replaced.
  OffloadConfig copyWith({
    bool? enabled,
    bool? discoverLAN,
    double? minLocalCapability,
    String? rendezvousUrl,
    List<Peer>? knownPeers,
  }) {
    return OffloadConfig(
      enabled: enabled ?? this.enabled,
      discoverLAN: discoverLAN ?? this.discoverLAN,
      minLocalCapability: minLocalCapability ?? this.minLocalCapability,
      rendezvousUrl: rendezvousUrl ?? this.rendezvousUrl,
      knownPeers: knownPeers ?? this.knownPeers,
    );
  }

  /// Encode for the Pigeon wire format.
  wire.OffloadConfigMessage toMessage() {
    return wire.OffloadConfigMessage(
      enabled: enabled,
      discoverLAN: discoverLAN,
      minLocalCapability: minLocalCapability,
      rendezvousUrl: rendezvousUrl,
      knownPeers:
          knownPeers?.map((Peer p) => p.toMessage()).toList(growable: false),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is OffloadConfig &&
        other.enabled == enabled &&
        other.discoverLAN == discoverLAN &&
        other.minLocalCapability == minLocalCapability &&
        other.rendezvousUrl == rendezvousUrl &&
        _listEquals(other.knownPeers, knownPeers);
  }

  @override
  int get hashCode => Object.hash(
        enabled,
        discoverLAN,
        minLocalCapability,
        rendezvousUrl,
        knownPeers == null ? null : Object.hashAll(knownPeers!),
      );

  @override
  String toString() {
    return 'OffloadConfig(enabled: $enabled, discoverLAN: $discoverLAN, '
        'minLocalCapability: $minLocalCapability, '
        'rendezvousUrl: $rendezvousUrl, knownPeers: $knownPeers)';
  }
}

/// Peer dvai-bridge instance discovered on the LAN or via rendezvous.
/// Mirrors the `Peer` shape on every other SDK 1:1.
@immutable
class Peer {
  /// Construct a [Peer].
  const Peer({
    required this.deviceId,
    required this.deviceName,
    required this.dvaiVersion,
    required this.baseUrl,
    required this.loadedModels,
    required this.capability,
    required this.via,
    required this.secure,
    required this.lastSeenAt,
  });

  /// Decode from the Pigeon wire format.
  factory Peer.fromMessage(wire.PeerMessage msg) {
    return Peer(
      deviceId: msg.deviceId,
      deviceName: msg.deviceName,
      dvaiVersion: msg.dvaiVersion,
      baseUrl: msg.baseUrl,
      loadedModels: List<String>.unmodifiable(msg.loadedModels),
      capability: _decodeCapability(msg.capability),
      via: PeerVia.fromWire(msg.via) ?? PeerVia.custom,
      secure: msg.secure,
      lastSeenAt: msg.lastSeenAt,
    );
  }

  /// Stable per-install device ID of the peer.
  final String deviceId;

  /// Human-readable hint (iOS device name, hostname, etc.).
  final String deviceName;

  /// Library SemVer the peer is running.
  final String dvaiVersion;

  /// OpenAI-compatible base URL the peer's local server exposes.
  final String baseUrl;

  /// Models the peer claims to have loaded right now.
  final List<String> loadedModels;

  /// Peer-reported capability map: `{ modelId → tok/s }`. Advisory.
  final Map<String, double> capability;

  /// Discovery source — useful for diagnostics and the structured-error
  /// response.
  final PeerVia via;

  /// Whether the peer's URL uses TLS.
  final bool secure;

  /// Last-seen unix ms — discovery sources update this.
  final int lastSeenAt;

  /// Encode for the Pigeon wire format. Capability is flattened into a
  /// `[k1, v1, k2, v2, ...]` `List<Object?>` to keep the wire format
  /// simple across iOS / Android (Pigeon's nested-Map support is
  /// generic-typed only when the value is non-nullable).
  wire.PeerMessage toMessage() {
    final List<Object?> capList = <Object?>[];
    capability.forEach((String key, double value) {
      capList
        ..add(key)
        ..add(value);
    });
    return wire.PeerMessage(
      deviceId: deviceId,
      deviceName: deviceName,
      dvaiVersion: dvaiVersion,
      baseUrl: baseUrl,
      loadedModels: List<String>.from(loadedModels),
      capability: capList,
      via: via.wireValue,
      secure: secure,
      lastSeenAt: lastSeenAt,
    );
  }

  static Map<String, double> _decodeCapability(List<Object?>? wireFormat) {
    final Map<String, double> out = <String, double>{};
    if (wireFormat == null) {
      return out;
    }
    for (int i = 0; i + 1 < wireFormat.length; i += 2) {
      final Object? key = wireFormat[i];
      final Object? value = wireFormat[i + 1];
      if (key is String && value is num) {
        out[key] = value.toDouble();
      }
    }
    return out;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is Peer &&
        other.deviceId == deviceId &&
        other.deviceName == deviceName &&
        other.dvaiVersion == dvaiVersion &&
        other.baseUrl == baseUrl &&
        _listEquals(other.loadedModels, loadedModels) &&
        _mapEquals(other.capability, capability) &&
        other.via == via &&
        other.secure == secure &&
        other.lastSeenAt == lastSeenAt;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        deviceName,
        dvaiVersion,
        baseUrl,
        Object.hashAll(loadedModels),
        Object.hashAll(capability.entries.map((MapEntry<String, double> e) =>
            Object.hash(e.key, e.value))),
        via,
        secure,
        lastSeenAt,
      );

  @override
  String toString() {
    return 'Peer(deviceId: $deviceId, deviceName: $deviceName, '
        'dvaiVersion: $dvaiVersion, baseUrl: $baseUrl, via: $via)';
  }
}

/// Discovery source a [Peer] was learned from.
enum PeerVia {
  /// Multicast DNS / Bonjour / DNS-SD on the local network.
  mdns,

  /// Static peer list passed via [OffloadConfig.knownPeers].
  static_,

  /// Pre-paired via the rendezvous server (internet path).
  rendezvous,

  /// Plug-in source supplied by the consumer app.
  custom;

  /// Wire-format identifier mirrored across every SDK. Always lowercase
  /// ASCII; matches the iOS / Android / RN wire encoding.
  String get wireValue {
    switch (this) {
      case PeerVia.mdns:
        return 'mdns';
      case PeerVia.static_:
        return 'static';
      case PeerVia.rendezvous:
        return 'rendezvous';
      case PeerVia.custom:
        return 'custom';
    }
  }

  /// Parse a wire-format string. Returns null on unknown values.
  static PeerVia? fromWire(String value) {
    switch (value) {
      case 'mdns':
        return PeerVia.mdns;
      case 'static':
        return PeerVia.static_;
      case 'rendezvous':
        return PeerVia.rendezvous;
      case 'custom':
        return PeerVia.custom;
      default:
        return null;
    }
  }
}

/// A request for the consumer app to approve (or deny) pairing with a
/// remote peer. Surfaced via [DVAIBridge.pairingRequests]; respond by
/// calling [PairingRequest.respond] (or
/// [DVAIBridge.respondToPairingRequest] with the [id]).
@immutable
class PairingRequest {
  /// Construct a [PairingRequest]. Most callers receive this from
  /// [DVAIBridge.pairingRequests] rather than constructing manually.
  const PairingRequest({
    required this.id,
    required this.peer,
    required this.expiresAt,
    required Future<void> Function(String requestId, bool approved) respond,
  }) : _respond = respond;

  /// Decode from the Pigeon wire format. The `respond` callback closes
  /// over a reference to the [DVAIBridge] facade so consumers can call
  /// `req.respond(approved: true)` directly without holding a separate
  /// reference to the bridge singleton.
  factory PairingRequest.fromMessage(
    wire.PairingRequestMessage msg, {
    required Future<void> Function(String requestId, bool approved) respond,
  }) {
    return PairingRequest(
      id: msg.id,
      peer: Peer.fromMessage(msg.peer),
      expiresAt: msg.expiresAt,
      respond: respond,
    );
  }

  /// Stable id used to correlate the response.
  final String id;

  /// The peer requesting to pair.
  final Peer peer;

  /// Unix-ms deadline after which the pending request is auto-denied.
  final int expiresAt;

  final Future<void> Function(String requestId, bool approved) _respond;

  /// Convenience accessor for `peer.deviceName`.
  String get peerDeviceName => peer.deviceName;

  /// Resolve the request with the user's decision. Idempotent —
  /// responding twice resolves cleanly the second time.
  ///
  /// Equivalent to [DVAIBridge.respondToPairingRequest] with [id]
  /// already filled in. Most consumers prefer this method.
  Future<void> respond({required bool approved}) {
    return _respond(id, approved);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is PairingRequest &&
        other.id == id &&
        other.peer == peer &&
        other.expiresAt == expiresAt;
  }

  @override
  int get hashCode => Object.hash(id, peer, expiresAt);

  @override
  String toString() {
    return 'PairingRequest(id: $id, peer: $peer, expiresAt: $expiresAt)';
  }
}

bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) {
    return true;
  }
  if (a == null || b == null) {
    return false;
  }
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

bool _mapEquals<K, V>(Map<K, V>? a, Map<K, V>? b) {
  if (identical(a, b)) {
    return true;
  }
  if (a == null || b == null) {
    return false;
  }
  if (a.length != b.length) {
    return false;
  }
  for (final MapEntry<K, V> entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

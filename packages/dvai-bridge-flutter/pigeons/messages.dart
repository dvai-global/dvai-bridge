// Pigeon spec for `dvai_bridge`. Source of truth for the platform-channel
// layer; generated outputs land in:
//
//   - lib/src/messages.g.dart
//   - ios/Classes/Messages.g.swift
//   - android/src/main/kotlin/co/deepvoiceai/bridge/flutter/Messages.g.kt
//
// The generated files are gitignored. Run before `flutter analyze` /
// `flutter test`:
//
//     cd packages/dvai-bridge-flutter
//     dart run pigeon --input pigeons/messages.dart
//
// Conventions:
//
//   - All `@HostApi()` methods are `@async` so they map to Dart `Future<T>`
//     and Swift / Kotlin completion-handler signatures. The native plugin
//     impls bridge `await DVAIBridge.shared.start(...)` (Swift) or
//     `DVAIBridge.start(...)` (Kotlin) into the completion handler from
//     inside a `Task { ... }` / `pluginScope.launch { ... }` block.
//
//   - `BackendKind` is serialized as a lowercase string ("auto", "llama",
//     ...). The Dart facade exposes it as a real `enum`; the messages-layer
//     uses string for forward-compat (we can add new backends without
//     re-running pigeon on consumers' generated code).
//
//   - `ProgressEventMessage` mirrors the Phase 3E React Native JSON shape
//     so the family-wide error / progress contract stays consistent across
//     iOS / Android / RN / Flutter.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/Classes/Messages.g.swift',
    swiftOptions: SwiftOptions(),
    kotlinOut:
        'android/src/main/kotlin/co/deepvoiceai/bridge/flutter/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'co.deepvoiceai.bridge.flutter'),
    dartPackageName: 'dvai_bridge',
  ),
)
/// Pigeon-side carrier of [StartOptions]. All fields except [backend] are
/// optional; the native side fills in defaults matching the underlying
/// SDK. `backend` is a lowercase string ("auto" | "llama" | ...).
class StartOptionsMessage {
  StartOptionsMessage({
    required this.backend,
    this.modelPath,
    this.tokenizerPath,
    this.mmprojPath,
    this.chatTemplate,
    this.modelId,
    this.gpuLayers,
    this.contextSize,
    this.threads,
    this.embeddingMode,
    this.visionEnabled,
    this.temperature,
    this.topP,
    this.topK,
    this.maxNewTokens,
    this.httpBasePort,
    this.httpMaxPortAttempts,
    this.corsOrigin,
    this.logLevel,
    this.autoUnloadOnLowMemory,
  });

  String backend;
  String? modelPath;
  String? tokenizerPath;
  String? mmprojPath;
  String? chatTemplate;
  String? modelId;
  int? gpuLayers;
  int? contextSize;
  int? threads;
  bool? embeddingMode;
  bool? visionEnabled;
  double? temperature;
  double? topP;
  int? topK;
  int? maxNewTokens;
  int? httpBasePort;
  int? httpMaxPortAttempts;
  // Wildcard (single string) or comma-joined explicit allowlist; the Dart
  // facade encodes a `List<String>` as comma-joined for the wire format.
  String? corsOrigin;
  String? logLevel;
  bool? autoUnloadOnLowMemory;
  // v3.0+ — distributed inference / device offload. Optional; when
  // present and `enabled` is true, the native side runs mDNS discovery
  // and (optionally) connects to a rendezvous server to pair with peer
  // dvai-bridge instances and offload inference requests when the
  // local device's capability score is below the configured floor.
  OffloadConfigMessage? offload;
}

/// Pigeon-side carrier of [OffloadConfig]. Functions (`onPairingRequest`,
/// `onOffload`, `customDiscovery`) from the JS-side `OffloadConfig` are
/// not representable across the Pigeon channel, so they're surfaced via
/// the `pairingRequestEvents()` event-channel API instead.
class OffloadConfigMessage {
  OffloadConfigMessage({
    required this.enabled,
    this.discoverLAN,
    this.minLocalCapability,
    this.rendezvousUrl,
    this.knownPeers,
  });

  bool enabled;
  bool? discoverLAN;
  double? minLocalCapability;
  String? rendezvousUrl;
  List<PeerMessage>? knownPeers;
}

/// Pigeon-side carrier of [Peer]. Capability is encoded as a flat
/// `[k1, v1, k2, v2, ...]` `List<Object?>` because Pigeon's nested-Map
/// support is generic-typed only when the value is non-nullable.
class PeerMessage {
  PeerMessage({
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

  String deviceId;
  String deviceName;
  String dvaiVersion;
  String baseUrl;
  List<String> loadedModels;
  // Flat alternating-pair encoding for `Map<String, double>`.
  List<Object?> capability;
  // One of: "mdns" | "static" | "rendezvous" | "custom".
  String via;
  bool secure;
  int lastSeenAt;
}

/// Pigeon-side carrier of [PairingRequest]. Emitted on the
/// `pairingRequestEvents()` event channel when a remote peer requests
/// to pair with this device. The Dart side wires up
/// [DVAIBridge.respondToPairingRequest] to the `respond` parameter so
/// consumers can call `req.respond(approved: true)` directly.
class PairingRequestMessage {
  PairingRequestMessage({
    required this.id,
    required this.peer,
    required this.expiresAt,
  });

  String id;
  PeerMessage peer;
  int expiresAt;
}

/// Pigeon-side carrier of [BoundServer].
class BoundServerMessage {
  BoundServerMessage({
    required this.baseUrl,
    required this.port,
    required this.backend,
    required this.modelId,
  });

  String baseUrl;
  int port;
  String backend;
  String modelId;
}

/// Pigeon-side carrier of [StatusInfo].
class StatusInfoMessage {
  StatusInfoMessage({
    required this.running,
    this.baseUrl,
    this.port,
    this.backend,
    this.modelId,
  });

  bool running;
  String? baseUrl;
  int? port;
  String? backend;
  String? modelId;
}

/// Pigeon-side carrier of [DownloadOptions].
class DownloadOptionsMessage {
  DownloadOptionsMessage({
    required this.url,
    required this.sha256,
    this.destFilename,
    this.headers,
  });

  String url;
  String sha256;
  String? destFilename;
  // Optional extra HTTP headers, encoded as alternating key,value pairs in a
  // List<String>. Pigeon's nested-Map support is generic-typed only when the
  // value is non-nullable, so we encode as a flat list to keep the wire
  // format simple across iOS / Android.
  List<String?>? headers;
}

/// Pigeon-side carrier of [DownloadResult].
class DownloadResultMessage {
  DownloadResultMessage({
    required this.path,
    required this.sha256,
    required this.sizeBytes,
    this.cached,
  });

  String path;
  String sha256;
  int sizeBytes;
  bool? cached;
}

/// Pigeon-side carrier of [ProgressEvent]. `kind` is one of
/// "started" | "progress" | "completed" | "failed". `phase` is one of
/// "start" | "stop" | "download" | "load" | "ready" | "verify" | "error".
class ProgressEventMessage {
  ProgressEventMessage({
    required this.kind,
    required this.phase,
    this.percent,
    this.message,
    this.errorKind,
    this.errorMessage,
  });

  String kind;
  String phase;
  double? percent;
  String? message;
  String? errorKind;
  String? errorMessage;
}

/// Host-side (iOS / Android) lifecycle API. The Dart side calls into this;
/// the native plugin classes implement it.
@HostApi()
abstract class DVAIBridgeHostApi {
  @async
  BoundServerMessage startBridge(StartOptionsMessage opts);

  @async
  void stopBridge();

  @async
  StatusInfoMessage status();

  @async
  DownloadResultMessage downloadModel(DownloadOptionsMessage opts);

  /// v3.0+ — Phase 3 distributed inference. Resolve a pending pairing
  /// request emitted on the [pairingRequestEvents] channel. `requestId`
  /// matches the `id` field of the [PairingRequestMessage] payload.
  /// `approved=true` lets the inbound peer pair; `false` rejects.
  ///
  /// Idempotent — responding twice to the same `requestId` resolves
  /// cleanly on subsequent calls.
  @async
  void respondToPairingRequest(String requestId, bool approved);
}

/// Event-channel API exposing the native progress stream
/// (`DVAIBridge.shared.progressPublisher` on iOS / `DVAIBridge.progressFlow`
/// on Android) as a typed Dart `Stream<ProgressEventMessage>`.
@EventChannelApi()
abstract class DVAIBridgeEventApi {
  ProgressEventMessage progressEvents();

  /// v3.0+ — Phase 3 distributed inference. Native-side stream of
  /// [PairingRequestMessage]s emitted when a remote peer requests
  /// pairing. Surfaced on the Dart side as
  /// [DVAIBridge.pairingRequests].
  PairingRequestMessage pairingRequestEvents();
}

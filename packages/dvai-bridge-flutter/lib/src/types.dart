// Public Dart types for `dvai_bridge`. Each class has `toMessage()` and
// `fromMessage(...)` for round-tripping with the Pigeon-generated wire
// types in `messages.g.dart`. The wire types stay private to this package
// (the public re-export in `lib/dvai_bridge.dart` exposes only these
// hand-written classes).

import 'package:meta/meta.dart';

import 'messages.g.dart' as wire;
import 'offload.dart';

/// Inference backend selected via [StartOptions.backend]. The Dart API
/// exposes the **union** of every backend supported by either platform.
///
/// Cross-platform availability:
///
///  | Value          | iOS  | Android |
///  |----------------|:----:|:-------:|
///  | [auto]         |  ✓   |    ✓    |
///  | [llama]        |  ✓   |    ✓    |
///  | [foundation]   |  ✓   |    —    |
///  | [coreml]       |  ✓   |    —    |
///  | [mlx]          |  ✓*  |    —    |
///  | [mediapipe]    |  —   |    ✓    |
///  | [litert]       |  —   |    ✓    |
///
/// `*` MLX is SwiftPM-only — see the README's "MLX under CocoaPods" note.
///
/// Selecting a backend the running platform doesn't support throws a
/// [DVAIBridgeError] with `kind == DVAIBridgeErrorKind.backendUnavailable`.
/// The Dart facade pre-validates so callers fail fast before the platform
/// channel call.
enum BackendKind {
  /// Resolve the backend at runtime from the model file's extension.
  auto,

  /// llama.cpp-backed GGUF loader. Available on both iOS and Android.
  llama,

  /// Apple `FoundationModels` backend. iOS-only; SwiftPM-only.
  foundation,

  /// Apple Core ML backend (`.mlmodelc` / `.mlpackage`). iOS-only.
  coreml,

  /// Apple MLX backend. iOS-only; SwiftPM-only.
  mlx,

  /// Google MediaPipe LLM Inference (`.task`). Android-only.
  mediapipe,

  /// Google LiteRT-LM (`.tflite` / `.litertlm`). Android-only.
  litert;

  /// Wire-format identifier mirrored across iOS / Android / RN. Always
  /// lowercase ASCII; matches the generated `BackendKind` cases on both
  /// native sides.
  String get wireValue => name;

  /// Parse a wire-format string back into a [BackendKind]. Returns null
  /// if [value] doesn't match any known backend (defensive — the native
  /// side controls the wire format, so unknowns indicate a version skew).
  static BackendKind? fromWire(String value) {
    for (final BackendKind kind in BackendKind.values) {
      if (kind.wireValue == value) {
        return kind;
      }
    }
    return null;
  }
}

/// CORS allow-origin policy for the embedded HTTP server. Mirrors the
/// `CorsOrigin` shape on iOS / Android.
@immutable
sealed class CorsOrigin {
  const CorsOrigin();

  /// Wildcard policy: any origin allowed.
  const factory CorsOrigin.any() = _CorsOriginAny;

  /// Single-origin policy.
  const factory CorsOrigin.exact(String origin) = _CorsOriginExact;

  /// Explicit allowlist policy.
  const factory CorsOrigin.list(List<String> origins) = _CorsOriginList;

  /// Wire-format encoding: `"*"`, a single origin string, or a
  /// comma-joined string for the list form. Both native sides parse the
  /// same shape.
  String toWire();
}

class _CorsOriginAny extends CorsOrigin {
  const _CorsOriginAny();
  @override
  String toWire() => '*';
}

class _CorsOriginExact extends CorsOrigin {
  const _CorsOriginExact(this.origin);
  final String origin;
  @override
  String toWire() => origin;
}

class _CorsOriginList extends CorsOrigin {
  const _CorsOriginList(this.origins);
  final List<String> origins;
  @override
  String toWire() => origins.join(',');
}

/// Log-verbosity hint for the iOS-side bridge. Ignored on Android (which
/// has its own `Log` plumbing).
enum LogLevel {
  /// Suppress all bridge-emitted logs.
  silent,

  /// Default level: lifecycle + warnings.
  info,

  /// Verbose: include debug traces. Slows down `start()` measurably.
  debug;

  /// Wire-format identifier.
  String get wireValue => name;
}

/// Options for [DVAIBridge.start]. Shape mirrors the iOS `DVAIBridgeConfig`
/// and Android `StartOptions` 1:1, with [backend] required and the rest
/// optional. Per-backend defaults match the underlying SDKs — see the
/// per-platform docs for the full list.
@immutable
class StartOptions {
  /// Construct a [StartOptions]. [backend] is required; everything else
  /// is optional and falls back to the underlying SDK's default.
  const StartOptions({
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
    this.offload,
  });

  /// Which backend to start. Pass [BackendKind.auto] to resolve at runtime.
  final BackendKind backend;

  /// Filesystem path to the model checkpoint.
  ///
  /// Required for `llama` (`.gguf`), `mediapipe` (`.task`), `litert`
  /// (`.tflite` / `.litertlm`), and `coreml` (`.mlmodelc` / `.mlpackage`)
  /// backends. For `mlx`, pass a HuggingFace model id (e.g.
  /// `"mlx-community/Llama-3.2-1B-Instruct-4bit"`). Optional for
  /// `foundation` (Apple's bundled model).
  final String? modelPath;

  /// Optional path to a directory containing `tokenizer.json`. Required for
  /// the LiteRT backend.
  final String? tokenizerPath;

  /// Optional multimodal projector path (Llama backend, vision/audio LLMs).
  final String? mmprojPath;

  /// Optional Jinja chat-template override (Llama backend). Falls back to
  /// the model's bundled template.
  final String? chatTemplate;

  /// Optional override for the model id surfaced via `/v1/models`.
  /// Defaults to filename minus extension.
  final String? modelId;

  /// Llama backend: layers offloaded to GPU. 99 = all, 0 = CPU only.
  /// Default: 99.
  final int? gpuLayers;

  /// Context window in tokens. Default: 2048.
  final int? contextSize;

  /// CPU thread count for inference. Default: 4.
  final int? threads;

  /// Llama backend: open in embedding-extraction mode rather than
  /// completion mode. Default: false.
  final bool? embeddingMode;

  /// MediaPipe backend: enable the LiteRT-LM vision backend (Gemma 3n).
  /// Default: false.
  final bool? visionEnabled;

  /// LiteRT backend: sampling temperature (0 = greedy). Default: 0.
  final double? temperature;

  /// LiteRT backend: nucleus-sampling cutoff (1 = disabled). Default: 1.
  final double? topP;

  /// LiteRT backend: top-K truncation (0 = disabled). Default: 0.
  final int? topK;

  /// LiteRT backend: hard cap on tokens generated per request. Default: 512.
  final int? maxNewTokens;

  /// First port the embedded HTTP server tries to bind. Default: 38883.
  final int? httpBasePort;

  /// Number of consecutive ports to try before giving up. Default: 16.
  final int? httpMaxPortAttempts;

  /// CORS allow-origin policy. Default: wildcard.
  final CorsOrigin? corsOrigin;

  /// iOS-only: log-verbosity. Default: [LogLevel.info].
  final LogLevel? logLevel;

  /// iOS-only: auto-unload the active model on iOS memory-pressure events.
  /// Default: false.
  final bool? autoUnloadOnLowMemory;

  /// v3.0+ — distributed inference / device offload.
  ///
  /// When `offload.enabled` is true, the native side runs mDNS
  /// discovery (and optionally a rendezvous WebSocket) to find peer
  /// dvai-bridge instances and offloads inference requests when the
  /// local device can't serve the model fast enough.
  ///
  /// Pairing-request UI is surfaced via
  /// [DVAIBridge.pairingRequests] — the function-typed
  /// `onPairingRequest` callback of the JS-side `OffloadConfig` isn't
  /// representable across the Pigeon channel, so Dart consumers
  /// listen to a [Stream] of [PairingRequest] values instead.
  final OffloadConfig? offload;

  /// Returns a copy of this object with the given fields replaced.
  StartOptions copyWith({
    BackendKind? backend,
    String? modelPath,
    String? tokenizerPath,
    String? mmprojPath,
    String? chatTemplate,
    String? modelId,
    int? gpuLayers,
    int? contextSize,
    int? threads,
    bool? embeddingMode,
    bool? visionEnabled,
    double? temperature,
    double? topP,
    int? topK,
    int? maxNewTokens,
    int? httpBasePort,
    int? httpMaxPortAttempts,
    CorsOrigin? corsOrigin,
    LogLevel? logLevel,
    bool? autoUnloadOnLowMemory,
    OffloadConfig? offload,
  }) {
    return StartOptions(
      backend: backend ?? this.backend,
      modelPath: modelPath ?? this.modelPath,
      tokenizerPath: tokenizerPath ?? this.tokenizerPath,
      mmprojPath: mmprojPath ?? this.mmprojPath,
      chatTemplate: chatTemplate ?? this.chatTemplate,
      modelId: modelId ?? this.modelId,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      contextSize: contextSize ?? this.contextSize,
      threads: threads ?? this.threads,
      embeddingMode: embeddingMode ?? this.embeddingMode,
      visionEnabled: visionEnabled ?? this.visionEnabled,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      topK: topK ?? this.topK,
      maxNewTokens: maxNewTokens ?? this.maxNewTokens,
      httpBasePort: httpBasePort ?? this.httpBasePort,
      httpMaxPortAttempts: httpMaxPortAttempts ?? this.httpMaxPortAttempts,
      corsOrigin: corsOrigin ?? this.corsOrigin,
      logLevel: logLevel ?? this.logLevel,
      autoUnloadOnLowMemory:
          autoUnloadOnLowMemory ?? this.autoUnloadOnLowMemory,
      offload: offload ?? this.offload,
    );
  }

  /// Encode for the Pigeon wire format.
  wire.StartOptionsMessage toMessage() {
    return wire.StartOptionsMessage(
      backend: backend.wireValue,
      modelPath: modelPath,
      tokenizerPath: tokenizerPath,
      mmprojPath: mmprojPath,
      chatTemplate: chatTemplate,
      modelId: modelId,
      gpuLayers: gpuLayers,
      contextSize: contextSize,
      threads: threads,
      embeddingMode: embeddingMode,
      visionEnabled: visionEnabled,
      temperature: temperature,
      topP: topP,
      topK: topK,
      maxNewTokens: maxNewTokens,
      httpBasePort: httpBasePort,
      httpMaxPortAttempts: httpMaxPortAttempts,
      corsOrigin: corsOrigin?.toWire(),
      logLevel: logLevel?.wireValue,
      autoUnloadOnLowMemory: autoUnloadOnLowMemory,
      offload: offload?.toMessage(),
    );
  }
}

/// Result of a successful [DVAIBridge.start] call. Mirrors iOS
/// `BoundServer` and Android `BoundServer`.
@immutable
class BoundServer {
  /// Construct a [BoundServer].
  const BoundServer({
    required this.baseUrl,
    required this.port,
    required this.backend,
    required this.modelId,
  });

  /// Decode from the Pigeon wire format.
  factory BoundServer.fromMessage(wire.BoundServerMessage msg) {
    return BoundServer(
      baseUrl: msg.baseUrl,
      port: msg.port,
      backend:
          BackendKind.fromWire(msg.backend) ?? BackendKind.auto,
      modelId: msg.modelId,
    );
  }

  /// Full base URL of the embedded OpenAI-compatible server, e.g.
  /// `http://127.0.0.1:38883/v1`.
  final String baseUrl;

  /// Port the HTTP server actually bound to.
  final int port;

  /// The backend that actually loaded — useful when [StartOptions.backend]
  /// was [BackendKind.auto].
  final BackendKind backend;

  /// Stable identifier for the loaded model. Surfaced in the `model`
  /// field of every OpenAI response.
  final String modelId;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is BoundServer &&
        other.baseUrl == baseUrl &&
        other.port == port &&
        other.backend == backend &&
        other.modelId == modelId;
  }

  @override
  int get hashCode => Object.hash(baseUrl, port, backend, modelId);

  @override
  String toString() {
    return 'BoundServer(baseUrl: $baseUrl, port: $port, backend: $backend, '
        'modelId: $modelId)';
  }
}

/// Read-only snapshot returned by [DVAIBridge.status].
@immutable
class StatusInfo {
  /// Construct a [StatusInfo].
  const StatusInfo({
    required this.running,
    this.baseUrl,
    this.port,
    this.backend,
    this.modelId,
  });

  /// Decode from the Pigeon wire format.
  factory StatusInfo.fromMessage(wire.StatusInfoMessage msg) {
    return StatusInfo(
      running: msg.running,
      baseUrl: msg.baseUrl,
      port: msg.port,
      backend:
          msg.backend == null ? null : BackendKind.fromWire(msg.backend!),
      modelId: msg.modelId,
    );
  }

  /// Whether a backend is currently active.
  final bool running;

  /// Base URL of the active server, when [running] is true.
  final String? baseUrl;

  /// Bound port, when [running] is true.
  final int? port;

  /// Active backend, when [running] is true.
  final BackendKind? backend;

  /// Active model id, when [running] is true.
  final String? modelId;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is StatusInfo &&
        other.running == running &&
        other.baseUrl == baseUrl &&
        other.port == port &&
        other.backend == backend &&
        other.modelId == modelId;
  }

  @override
  int get hashCode => Object.hash(running, baseUrl, port, backend, modelId);

  @override
  String toString() {
    return 'StatusInfo(running: $running, baseUrl: $baseUrl, port: $port, '
        'backend: $backend, modelId: $modelId)';
  }
}

/// Options for [DVAIBridge.downloadModel].
@immutable
class DownloadOptions {
  /// Construct a [DownloadOptions].
  const DownloadOptions({
    required this.url,
    required this.sha256,
    this.destFilename,
    this.headers,
  });

  /// Source URL. HTTPS only.
  final String url;

  /// Expected SHA-256 (lowercase hex). The downloader rejects mismatches
  /// and deletes the partial file.
  final String sha256;

  /// Optional override for the on-disk filename. Defaults to the URL's
  /// last path component.
  final String? destFilename;

  /// Optional extra HTTP request headers (e.g. `Authorization`).
  final Map<String, String>? headers;

  /// Encode for the Pigeon wire format. Headers are flattened into a
  /// `[k1, v1, k2, v2, ...]` `List<String?>` for cross-platform parity
  /// with the iOS / Android dictionary types.
  wire.DownloadOptionsMessage toMessage() {
    List<String?>? wireHeaders;
    final Map<String, String>? hs = headers;
    if (hs != null && hs.isNotEmpty) {
      wireHeaders = <String?>[];
      hs.forEach((String key, String value) {
        wireHeaders!
          ..add(key)
          ..add(value);
      });
    }
    return wire.DownloadOptionsMessage(
      url: url,
      sha256: sha256,
      destFilename: destFilename,
      headers: wireHeaders,
    );
  }
}

/// Result of a successful [DVAIBridge.downloadModel] call.
@immutable
class DownloadResult {
  /// Construct a [DownloadResult].
  const DownloadResult({
    required this.path,
    required this.sha256,
    required this.sizeBytes,
    this.cached,
  });

  /// Decode from the Pigeon wire format.
  factory DownloadResult.fromMessage(wire.DownloadResultMessage msg) {
    return DownloadResult(
      path: msg.path,
      sha256: msg.sha256,
      sizeBytes: msg.sizeBytes,
      cached: msg.cached,
    );
  }

  /// Absolute filesystem path of the cached file.
  final String path;

  /// SHA-256 of the cached file.
  final String sha256;

  /// File size in bytes.
  final int sizeBytes;

  /// Whether the cached copy was already present (no network traffic).
  final bool? cached;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is DownloadResult &&
        other.path == path &&
        other.sha256 == sha256 &&
        other.sizeBytes == sizeBytes &&
        other.cached == cached;
  }

  @override
  int get hashCode => Object.hash(path, sha256, sizeBytes, cached);

  @override
  String toString() {
    return 'DownloadResult(path: $path, sha256: $sha256, '
        'sizeBytes: $sizeBytes, cached: $cached)';
  }
}

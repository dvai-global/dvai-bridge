// Progress events emitted by the native side during start / stop /
// download lifecycles, plus the derived [DVAIBridgeState] view.

import 'package:meta/meta.dart';

import 'errors.dart';
import 'messages.g.dart' as wire;
import 'types.dart';

/// What happened. The native sides emit one event per phase transition.
enum ProgressKind {
  /// The phase began.
  started,

  /// In-flight progress update — usually carries [ProgressEvent.percent].
  progress,

  /// The phase succeeded.
  completed,

  /// The phase failed; [ProgressEvent.errorKind] / [ProgressEvent.errorMessage]
  /// carry the cause.
  failed;

  /// Wire-format identifier.
  String get wireValue => name;

  /// Parse a wire-format string. Returns null on unknown values.
  static ProgressKind? fromWire(String value) {
    for (final ProgressKind kind in ProgressKind.values) {
      if (kind.wireValue == value) {
        return kind;
      }
    }
    return null;
  }
}

/// Lifecycle phase a [ProgressEvent] relates to.
enum ProgressPhase {
  /// Backend boot — invoked from [DVAIBridge.start].
  start,

  /// Shutdown — invoked from [DVAIBridge.stop].
  stop,

  /// Model download — invoked from [DVAIBridge.downloadModel].
  download,

  /// Model load (a sub-phase of `start` on some backends).
  load,

  /// Server is bound and ready to accept requests.
  ready,

  /// Post-download checksum verification.
  verify,

  /// Generic error phase emitted for unrecoverable failures.
  error;

  /// Wire-format identifier.
  String get wireValue => name;

  /// Parse a wire-format string. Returns null on unknown values.
  static ProgressPhase? fromWire(String value) {
    for (final ProgressPhase phase in ProgressPhase.values) {
      if (phase.wireValue == value) {
        return phase;
      }
    }
    return null;
  }
}

/// One progress event from the native side. Both iOS and Android emit
/// exactly this shape (see Phase 3F spec §3.5); the fields below are the
/// union of every variant.
@immutable
class ProgressEvent {
  /// Construct a [ProgressEvent].
  const ProgressEvent({
    required this.kind,
    required this.phase,
    this.percent,
    this.message,
    this.errorKind,
    this.errorMessage,
  });

  /// Decode from the Pigeon wire format.
  factory ProgressEvent.fromMessage(wire.ProgressEventMessage msg) {
    return ProgressEvent(
      kind: ProgressKind.fromWire(msg.kind) ?? ProgressKind.progress,
      phase: ProgressPhase.fromWire(msg.phase) ?? ProgressPhase.error,
      percent: msg.percent,
      message: msg.message,
      errorKind: msg.errorKind == null
          ? null
          : DVAIBridgeErrorKind.fromWire(msg.errorKind!),
      errorMessage: msg.errorMessage,
    );
  }

  /// What happened.
  final ProgressKind kind;

  /// Which lifecycle phase the event relates to.
  final ProgressPhase phase;

  /// Percent in `[0, 100]` when [kind] is [ProgressKind.progress] and the
  /// underlying SDK can report progress; null when indeterminate.
  final double? percent;

  /// Optional human-readable message (used for log surfaces).
  final String? message;

  /// When [kind] is [ProgressKind.failed], the typed error discriminator.
  final DVAIBridgeErrorKind? errorKind;

  /// When [kind] is [ProgressKind.failed], the underlying message.
  final String? errorMessage;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is ProgressEvent &&
        other.kind == kind &&
        other.phase == phase &&
        other.percent == percent &&
        other.message == message &&
        other.errorKind == errorKind &&
        other.errorMessage == errorMessage;
  }

  @override
  int get hashCode =>
      Object.hash(kind, phase, percent, message, errorKind, errorMessage);

  @override
  String toString() {
    return 'ProgressEvent(kind: $kind, phase: $phase, percent: $percent, '
        'message: $message, errorKind: $errorKind, errorMessage: $errorMessage)';
  }
}

/// Reactive view of the running bridge state, surfaced by
/// `DVAIBridge.instance.stateStream`. Idiomatic Flutter consumers wrap
/// this in `StreamBuilder<DVAIBridgeState>`, a Riverpod
/// `StreamProvider<DVAIBridgeState>`, or a Bloc.
@immutable
class DVAIBridgeState {
  /// Construct a [DVAIBridgeState].
  const DVAIBridgeState({
    required this.isReady,
    this.baseUrl,
    this.port,
    this.backend,
    this.modelId,
    this.lastProgress,
    this.lastError,
  });

  /// The bridge is idle (post-stop / pre-start).
  static const DVAIBridgeState idle = DVAIBridgeState(isReady: false);

  /// Whether the bridge is currently running.
  final bool isReady;

  /// Active server URL, when [isReady] is true.
  final String? baseUrl;

  /// Active port, when [isReady] is true.
  final int? port;

  /// Active backend, when [isReady] is true.
  final BackendKind? backend;

  /// Active model id, when [isReady] is true.
  final String? modelId;

  /// Most recently observed progress event (for UI hints during boot /
  /// download).
  final ProgressEvent? lastProgress;

  /// Most recently observed error, if any.
  final DVAIBridgeError? lastError;

  /// Returns a copy of this object with the given fields replaced.
  DVAIBridgeState copyWith({
    bool? isReady,
    String? baseUrl,
    int? port,
    BackendKind? backend,
    String? modelId,
    ProgressEvent? lastProgress,
    DVAIBridgeError? lastError,
  }) {
    return DVAIBridgeState(
      isReady: isReady ?? this.isReady,
      baseUrl: baseUrl ?? this.baseUrl,
      port: port ?? this.port,
      backend: backend ?? this.backend,
      modelId: modelId ?? this.modelId,
      lastProgress: lastProgress ?? this.lastProgress,
      lastError: lastError ?? this.lastError,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is DVAIBridgeState &&
        other.isReady == isReady &&
        other.baseUrl == baseUrl &&
        other.port == port &&
        other.backend == backend &&
        other.modelId == modelId &&
        other.lastProgress == lastProgress &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hash(
        isReady,
        baseUrl,
        port,
        backend,
        modelId,
        lastProgress,
        lastError,
      );

  @override
  String toString() {
    return 'DVAIBridgeState(isReady: $isReady, baseUrl: $baseUrl, '
        'port: $port, backend: $backend, modelId: $modelId, '
        'lastProgress: $lastProgress, lastError: $lastError)';
  }
}

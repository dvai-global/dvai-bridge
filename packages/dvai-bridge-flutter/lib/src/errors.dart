// `DVAIBridgeError` is a sealed class so consumers can `switch` on the
// failure mode with exhaustiveness checking. The discriminator [kind]
// matches the Swift / Kotlin error code names exactly so the same error
// surface works regardless of which native side raised the failure.

import 'package:meta/meta.dart';

import 'types.dart';

/// Stable error-code surface mirrored by iOS `DVAIBridgeError` cases and
/// Android `DVAIBridgeError` subclasses. Consumers `switch` on the
/// [DVAIBridgeError.kind] field to react to failure modes.
enum DVAIBridgeErrorKind {
  /// `start()` was called while a previous bridge is still running.
  alreadyStarted,

  /// `stop()` (or another lifecycle call) was invoked when no bridge was
  /// active.
  notStarted,

  /// The supplied [StartOptions] were invalid (missing `modelPath` for a
  /// backend that requires one, malformed CORS origin, etc.).
  configurationInvalid,

  /// The chosen backend failed to load the model (corrupt file, missing
  /// tokenizer, OOM, ...).
  modelLoadFailed,

  /// The requested backend is not available on the running platform / build
  /// flavour (e.g. `mlx` under CocoaPods, `mediapipe` on iOS).
  backendUnavailable,

  /// A backend-specific runtime failure (HTTP server bind, inference
  /// crash, ...). Inspect [DVAIBridgeError.message] for details.
  backendError,

  /// Downloaded file's SHA-256 didn't match the expected checksum. The
  /// partial file has been deleted.
  checksumMismatch,

  /// Network or filesystem error during a `downloadModel()` call.
  downloadFailed;

  /// Wire-format identifier (matches the Swift / Kotlin error code names).
  String get wireValue => name;

  /// Parse a wire-format string back into a [DVAIBridgeErrorKind]. Returns
  /// null if [value] doesn't match any known kind (defensive — unknowns
  /// indicate a version skew between the Dart and native sides).
  static DVAIBridgeErrorKind? fromWire(String value) {
    for (final DVAIBridgeErrorKind kind in DVAIBridgeErrorKind.values) {
      if (kind.wireValue == value) {
        return kind;
      }
    }
    return null;
  }
}

/// The single error type thrown across the public Dart surface of
/// `dvai_bridge`. Sealed so consumers can exhaustively `switch` on
/// concrete subtypes; [kind] mirrors the iOS / Android wire identifier.
///
/// ```dart
/// try {
///   await DVAIBridge.instance.start(StartOptions(backend: BackendKind.auto));
/// } on DVAIBridgeError catch (err) {
///   switch (err.kind) {
///     case DVAIBridgeErrorKind.backendUnavailable:
///       // fall back to a different backend
///       break;
///     // ...
///   }
/// }
/// ```
@immutable
sealed class DVAIBridgeError implements Exception {
  const DVAIBridgeError._({required this.message, this.cause});

  /// Stable discriminator matching the iOS / Android error code names.
  DVAIBridgeErrorKind get kind;

  /// Human-readable description of the failure.
  final String message;

  /// Optional underlying error from the native side.
  final Object? cause;

  /// `start()` was called while a previous bridge is still running.
  const factory DVAIBridgeError.alreadyStarted({
    required BackendKind backend,
    required String baseUrl,
  }) = AlreadyStartedError;

  /// `stop()` was invoked with no active bridge.
  const factory DVAIBridgeError.notStarted({String message}) = NotStartedError;

  /// The supplied [StartOptions] were invalid.
  const factory DVAIBridgeError.configurationInvalid(String reason) =
      ConfigurationInvalidError;

  /// The chosen backend failed to load the model.
  const factory DVAIBridgeError.modelLoadFailed(String reason) =
      ModelLoadFailedError;

  /// The requested backend is not available on the running platform.
  const factory DVAIBridgeError.backendUnavailable({
    required BackendKind backend,
    required String reason,
  }) = BackendUnavailableError;

  /// A backend-specific runtime failure (HTTP bind, inference crash, etc.).
  const factory DVAIBridgeError.backendError(String underlying,
      {Object? cause}) = BackendErrorError;

  /// Downloaded file's SHA-256 didn't match the expected checksum.
  const factory DVAIBridgeError.checksumMismatch({
    required String expected,
    required String got,
  }) = ChecksumMismatchError;

  /// Network or filesystem error during a `downloadModel()` call.
  const factory DVAIBridgeError.downloadFailed(String reason,
      {Object? cause}) = DownloadFailedError;

  /// Reconstruct a [DVAIBridgeError] from a Pigeon `PlatformException`.
  /// Used by the facade to translate native failures into typed Dart
  /// errors. Falls back to [DVAIBridgeError.backendError] when the
  /// `code` field doesn't match any known [DVAIBridgeErrorKind].
  static DVAIBridgeError fromPlatform({
    required String? code,
    required String? message,
    Object? details,
  }) {
    final String safeMessage = message ?? 'Unknown native error';
    final DVAIBridgeErrorKind? parsed =
        code == null ? null : DVAIBridgeErrorKind.fromWire(code);
    switch (parsed) {
      case DVAIBridgeErrorKind.alreadyStarted:
        return DVAIBridgeError.alreadyStarted(
          backend: _backendFromDetails(details) ?? BackendKind.auto,
          baseUrl: _stringFromDetails(details, 'baseUrl') ?? '',
        );
      case DVAIBridgeErrorKind.notStarted:
        return DVAIBridgeError.notStarted(message: safeMessage);
      case DVAIBridgeErrorKind.configurationInvalid:
        return DVAIBridgeError.configurationInvalid(safeMessage);
      case DVAIBridgeErrorKind.modelLoadFailed:
        return DVAIBridgeError.modelLoadFailed(safeMessage);
      case DVAIBridgeErrorKind.backendUnavailable:
        return DVAIBridgeError.backendUnavailable(
          backend: _backendFromDetails(details) ?? BackendKind.auto,
          reason: safeMessage,
        );
      case DVAIBridgeErrorKind.backendError:
        return DVAIBridgeError.backendError(safeMessage, cause: details);
      case DVAIBridgeErrorKind.checksumMismatch:
        return DVAIBridgeError.checksumMismatch(
          expected: _stringFromDetails(details, 'expected') ?? '',
          got: _stringFromDetails(details, 'got') ?? '',
        );
      case DVAIBridgeErrorKind.downloadFailed:
        return DVAIBridgeError.downloadFailed(safeMessage, cause: details);
      case null:
        return DVAIBridgeError.backendError(safeMessage, cause: details);
    }
  }

  static BackendKind? _backendFromDetails(Object? details) {
    if (details is Map) {
      final Object? raw = details['backend'];
      if (raw is String) {
        return BackendKind.fromWire(raw);
      }
    }
    return null;
  }

  static String? _stringFromDetails(Object? details, String key) {
    if (details is Map) {
      final Object? raw = details[key];
      if (raw is String) {
        return raw;
      }
    }
    return null;
  }

  @override
  String toString() => 'DVAIBridgeError(${kind.wireValue}): $message';
}

/// Concrete [DVAIBridgeErrorKind.alreadyStarted] case.
final class AlreadyStartedError extends DVAIBridgeError {
  /// Construct an [AlreadyStartedError].
  const AlreadyStartedError({required this.backend, required this.baseUrl})
      : super._(
          message:
              'DVAIBridge is already running on $baseUrl with backend $backend.',
        );

  /// Backend the active bridge is running.
  final BackendKind backend;

  /// Base URL of the active bridge.
  final String baseUrl;

  @override
  DVAIBridgeErrorKind get kind => DVAIBridgeErrorKind.alreadyStarted;
}

/// Concrete [DVAIBridgeErrorKind.notStarted] case.
final class NotStartedError extends DVAIBridgeError {
  /// Construct a [NotStartedError].
  const NotStartedError({super.message = 'DVAIBridge is not running.'})
      : super._();

  @override
  DVAIBridgeErrorKind get kind => DVAIBridgeErrorKind.notStarted;
}

/// Concrete [DVAIBridgeErrorKind.configurationInvalid] case.
final class ConfigurationInvalidError extends DVAIBridgeError {
  /// Construct a [ConfigurationInvalidError].
  const ConfigurationInvalidError(String reason) : super._(message: reason);

  @override
  DVAIBridgeErrorKind get kind => DVAIBridgeErrorKind.configurationInvalid;
}

/// Concrete [DVAIBridgeErrorKind.modelLoadFailed] case.
final class ModelLoadFailedError extends DVAIBridgeError {
  /// Construct a [ModelLoadFailedError].
  const ModelLoadFailedError(String reason) : super._(message: reason);

  @override
  DVAIBridgeErrorKind get kind => DVAIBridgeErrorKind.modelLoadFailed;
}

/// Concrete [DVAIBridgeErrorKind.backendUnavailable] case.
final class BackendUnavailableError extends DVAIBridgeError {
  /// Construct a [BackendUnavailableError].
  const BackendUnavailableError({
    required this.backend,
    required String reason,
  }) : super._(message: reason);

  /// The unsupported backend.
  final BackendKind backend;

  @override
  DVAIBridgeErrorKind get kind => DVAIBridgeErrorKind.backendUnavailable;
}

/// Concrete [DVAIBridgeErrorKind.backendError] case.
final class BackendErrorError extends DVAIBridgeError {
  /// Construct a [BackendErrorError].
  const BackendErrorError(String underlying, {super.cause})
      : super._(message: underlying);

  @override
  DVAIBridgeErrorKind get kind => DVAIBridgeErrorKind.backendError;
}

/// Concrete [DVAIBridgeErrorKind.checksumMismatch] case.
final class ChecksumMismatchError extends DVAIBridgeError {
  /// Construct a [ChecksumMismatchError].
  const ChecksumMismatchError({required this.expected, required this.got})
      : super._(
          message:
              'Downloaded file SHA-256 mismatch: expected $expected, got $got.',
        );

  /// Expected SHA-256 (lowercase hex).
  final String expected;

  /// Actual SHA-256 (lowercase hex).
  final String got;

  @override
  DVAIBridgeErrorKind get kind => DVAIBridgeErrorKind.checksumMismatch;
}

/// Concrete [DVAIBridgeErrorKind.downloadFailed] case.
final class DownloadFailedError extends DVAIBridgeError {
  /// Construct a [DownloadFailedError].
  const DownloadFailedError(String reason, {super.cause})
      : super._(message: reason);

  @override
  DVAIBridgeErrorKind get kind => DVAIBridgeErrorKind.downloadFailed;
}

// Public Dart facade for `dvai_bridge`. Translates the typed Dart API
// into Pigeon-generated platform-channel calls, and exposes the typed
// `EventChannel` as `progressStream` / a derived `stateStream`.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show PlatformException;
import 'package:meta/meta.dart';

import 'errors.dart';
import 'license/license_validator.dart';
import 'license/types.dart';
import 'messages.g.dart' as wire;
import 'offload.dart';
import 'progress.dart';
import 'types.dart';

/// BackendKind values that only run on iOS. Selecting one on Android
/// throws [DVAIBridgeError.backendUnavailable] eagerly.
const Set<BackendKind> _iosOnly = <BackendKind>{
  BackendKind.foundation,
  BackendKind.coreml,
  BackendKind.mlx,
};

/// BackendKind values that only run on Android.
const Set<BackendKind> _androidOnly = <BackendKind>{
  BackendKind.mediapipe,
  BackendKind.litert,
};

/// Abstraction over `dart:io`'s `Platform` so unit tests can inject a
/// fake without depending on `package:flutter_test`'s host-OS detection.
@visibleForTesting
abstract class PlatformAdapter {
  /// Returns true on iOS.
  bool get isIOS;

  /// Returns true on Android.
  bool get isAndroid;
}

class _DartIoPlatformAdapter implements PlatformAdapter {
  const _DartIoPlatformAdapter();
  @override
  bool get isIOS => Platform.isIOS;
  @override
  bool get isAndroid => Platform.isAndroid;
}

/// Abstraction over the Pigeon-generated `progressEvents()` top-level
/// helper so unit tests can inject a fake event stream without binding a
/// real platform `EventChannel`.
@visibleForTesting
abstract class ProgressEventChannel {
  /// Returns the broadcast stream of progress events from the native side.
  Stream<wire.ProgressEventMessage> events();
}

class _PigeonProgressEventChannel implements ProgressEventChannel {
  const _PigeonProgressEventChannel();
  @override
  Stream<wire.ProgressEventMessage> events() => wire.progressEvents();
}

/// Abstraction over the Pigeon-generated `pairingRequestEvents()`
/// top-level helper. v3.0+ — distributed inference. Tests inject a
/// fake stream so the facade's [DVAIBridge.pairingRequests] surface
/// can be exercised without binding a real platform `EventChannel`.
@visibleForTesting
abstract class PairingRequestEventChannel {
  /// Returns the broadcast stream of pairing-request events from the
  /// native side.
  Stream<wire.PairingRequestMessage> events();
}

class _PigeonPairingRequestEventChannel implements PairingRequestEventChannel {
  const _PigeonPairingRequestEventChannel();
  @override
  Stream<wire.PairingRequestMessage> events() => wire.pairingRequestEvents();
}

/// Empty stream placeholder used by [DVAIBridge.test] when the test
/// doesn't care about pairing-request events.
class _NeverPairingRequestEventChannel implements PairingRequestEventChannel {
  const _NeverPairingRequestEventChannel();
  @override
  Stream<wire.PairingRequestMessage> events() =>
      const Stream<wire.PairingRequestMessage>.empty();
}

/// Factory for the offline license validator. The default factory in
/// production code constructs a real [LicenseValidator]; unit tests
/// inject a fake that returns a deterministic [LicenseStatus] without
/// hitting the filesystem or asset bundle.
@visibleForTesting
typedef LicenseValidatorFactory = LicenseValidator Function(
  LicenseValidatorOptions opts,
);

LicenseValidator _defaultLicenseValidatorFactory(
  LicenseValidatorOptions opts,
) =>
    LicenseValidator(opts);

/// Public facade for the DVAIBridge Flutter plugin. Use the
/// [DVAIBridge.instance] singleton:
///
/// ```dart
/// import 'package:dvai_bridge/dvai_bridge.dart';
///
/// final BoundServer server = await DVAIBridge.instance.start(
///   StartOptions(backend: BackendKind.auto, modelPath: '/path/to/model.gguf'),
/// );
/// print(server.baseUrl); // http://127.0.0.1:38883/v1
/// await DVAIBridge.instance.stop();
/// ```
///
/// All methods are async and throw [DVAIBridgeError] on failure. The
/// reactive [stateStream] / [progressStream] getters expose the native
/// progress publisher as Dart broadcast streams.
class DVAIBridge {
  /// Process-wide singleton, mirroring `DVAIBridge.shared` (iOS) and
  /// `DVAIBridge` `object` (Android). Most apps use this directly.
  static final DVAIBridge instance = DVAIBridge._(
    api: wire.DVAIBridgeHostApi(),
    eventChannel: const _PigeonProgressEventChannel(),
    pairingEventChannel: const _PigeonPairingRequestEventChannel(),
    platform: const _DartIoPlatformAdapter(),
    licenseValidatorFactory: _defaultLicenseValidatorFactory,
  );

  DVAIBridge._({
    required wire.DVAIBridgeHostApi api,
    required ProgressEventChannel eventChannel,
    required PairingRequestEventChannel pairingEventChannel,
    required PlatformAdapter platform,
    required LicenseValidatorFactory licenseValidatorFactory,
  })  : _api = api,
        _eventChannel = eventChannel,
        _pairingEventChannel = pairingEventChannel,
        _platform = platform,
        _licenseValidatorFactory = licenseValidatorFactory;

  /// Construct a [DVAIBridge] for unit testing. Pass a mocked
  /// [wire.DVAIBridgeHostApi] and a fake [ProgressEventChannel] /
  /// [PairingRequestEventChannel] so the facade's behaviour can be
  /// exercised without a real platform binding.
  @visibleForTesting
  factory DVAIBridge.test({
    required wire.DVAIBridgeHostApi api,
    required ProgressEventChannel eventChannel,
    required PlatformAdapter platform,
    PairingRequestEventChannel? pairingEventChannel,
    LicenseValidatorFactory? licenseValidatorFactory,
  }) {
    return DVAIBridge._(
      api: api,
      eventChannel: eventChannel,
      pairingEventChannel:
          pairingEventChannel ?? const _NeverPairingRequestEventChannel(),
      platform: platform,
      licenseValidatorFactory:
          licenseValidatorFactory ?? _defaultLicenseValidatorFactory,
    );
  }

  final wire.DVAIBridgeHostApi _api;
  final ProgressEventChannel _eventChannel;
  final PairingRequestEventChannel _pairingEventChannel;
  final PlatformAdapter _platform;
  final LicenseValidatorFactory _licenseValidatorFactory;
  Stream<PairingRequest>? _pairingRequestsStream;

  // Lazy progress / state plumbing.
  Stream<ProgressEvent>? _progressStream;
  StreamController<DVAIBridgeState>? _stateController;
  StreamSubscription<ProgressEvent>? _progressSubscription;
  DVAIBridgeState _latestState = DVAIBridgeState.idle;

  /// Boot the embedded HTTP server with the chosen backend. Resolves
  /// with a [BoundServer] once the server is listening.
  ///
  /// Before the native call, runs the offline JWT license check (see
  /// [LicenseValidator.validateAndAssert]) — in production builds with
  /// no valid commercial or trial license, this throws a
  /// [LicenseRequiredException] before the bridge starts. Debug /
  /// profile builds and `DVAI_FORCE_DEV=1` environments bypass the
  /// check entirely.
  ///
  /// On a successful start, the resolved [LicenseStatus] is attached
  /// to [BoundServer.licenseStatus] so host-app dashboards can surface
  /// the licensee / expiry.
  ///
  /// Throws [DVAIBridgeError] for native-side failures and
  /// [LicenseRequiredException] for license failures.
  Future<BoundServer> start(StartOptions opts) async {
    _assertBackendAvailable(opts.backend);

    final LicenseValidator validator = _licenseValidatorFactory(
      LicenseValidatorOptions(
        token: opts.licenseToken,
        path: opts.licenseKeyPath,
      ),
    );
    final LicenseStatus licenseStatus = await validator.validateAndAssert();

    try {
      final wire.BoundServerMessage msg =
          await _api.startBridge(opts.toMessage());
      return BoundServer.fromMessage(msg, licenseStatus: licenseStatus);
    } on PlatformException catch (err) {
      throw DVAIBridgeError.fromPlatform(
        code: err.code,
        message: err.message,
        details: err.details,
      );
    }
  }

  /// Stop the active backend. Idempotent — calling when nothing is running
  /// resolves cleanly.
  Future<void> stop() async {
    try {
      await _api.stopBridge();
    } on PlatformException catch (err) {
      throw DVAIBridgeError.fromPlatform(
        code: err.code,
        message: err.message,
        details: err.details,
      );
    }
  }

  /// Read the current bridge status.
  Future<StatusInfo> status() async {
    try {
      final wire.StatusInfoMessage msg = await _api.status();
      return StatusInfo.fromMessage(msg);
    } on PlatformException catch (err) {
      throw DVAIBridgeError.fromPlatform(
        code: err.code,
        message: err.message,
        details: err.details,
      );
    }
  }

  /// v3.2 — pre-init hardware assessment.
  ///
  /// Returns a JSON-shaped [HardwareAssessment] describing how this
  /// device would handle local inference, BEFORE any model
  /// download/load. The SDK never shows UI for hardware decisions;
  /// consumer apps query this and decide their own UX based on
  /// [HardwareAssessment.mode].
  ///
  /// Defaults match the native sides (3.0 / 10.0 tok/s). Pass
  /// overrides matching your `OffloadConfig` if you've customized.
  Future<HardwareAssessment> assessHardware({
    double hardwareMinimum = 3.0,
    double minLocalCapability = 10.0,
  }) async {
    try {
      final wire.HardwareAssessmentMessage msg =
          await _api.assessHardware(hardwareMinimum, minLocalCapability);
      return HardwareAssessment.fromMessage(msg);
    } on PlatformException catch (err) {
      throw DVAIBridgeError.fromPlatform(
        code: err.code,
        message: err.message,
        details: err.details,
      );
    }
  }

  /// Download a model file with SHA-256 verification. Resolves with the
  /// cached file's path on success.
  Future<DownloadResult> downloadModel(DownloadOptions opts) async {
    try {
      final wire.DownloadResultMessage msg =
          await _api.downloadModel(opts.toMessage());
      return DownloadResult.fromMessage(msg);
    } on PlatformException catch (err) {
      throw DVAIBridgeError.fromPlatform(
        code: err.code,
        message: err.message,
        details: err.details,
      );
    }
  }

  /// v3.0+ — distributed inference. Stream of [PairingRequest]s emitted
  /// when a remote peer requests pairing with this device. Idiomatic
  /// Riverpod / Bloc consumers wrap this in a `StreamProvider` /
  /// `BlocListener`; respond by calling [PairingRequest.respond] with
  /// the user's decision.
  ///
  /// ```dart
  /// DVAIBridge.instance.pairingRequests.listen((req) async {
  ///   final approved = await myUiConfirm(req.peerDeviceName);
  ///   await req.respond(approved: approved);
  /// });
  /// ```
  Stream<PairingRequest> get pairingRequests {
    return _pairingRequestsStream ??= _pairingEventChannel
        .events()
        .map(_decodePairingRequest)
        .asBroadcastStream();
  }

  PairingRequest _decodePairingRequest(wire.PairingRequestMessage msg) {
    return PairingRequest.fromMessage(
      msg,
      respond: respondToPairingRequest,
    );
  }

  /// v3.0+ — distributed inference. Resolve a pending [PairingRequest]
  /// by `id` with the user's decision. Idempotent — responding twice
  /// to the same `requestId` resolves cleanly the second time.
  ///
  /// Most consumers should prefer [PairingRequest.respond] (which
  /// closes over the `id` for them) over calling this directly.
  Future<void> respondToPairingRequest(String requestId, bool approved) async {
    try {
      await _api.respondToPairingRequest(requestId, approved);
    } on PlatformException catch (err) {
      throw DVAIBridgeError.fromPlatform(
        code: err.code,
        message: err.message,
        details: err.details,
      );
    }
  }

  /// Broadcast stream of typed [ProgressEvent]s emitted during
  /// `start()` / `stop()` / `downloadModel()` calls. Both iOS and Android
  /// emit the same shape; the listener is invoked on the platform
  /// thread's dispatch.
  Stream<ProgressEvent> get progressStream {
    return _progressStream ??=
        _eventChannel.events().map(ProgressEvent.fromMessage).asBroadcastStream();
  }

  /// Derived "is the bridge running" view. Latest-value cache, suitable
  /// for `StreamBuilder<DVAIBridgeState>`. The first listener bootstraps
  /// the stream with the result of [status]() so a `StreamBuilder` doesn't
  /// have to spin in a loading state when the bridge is already running.
  Stream<DVAIBridgeState> get stateStream {
    final StreamController<DVAIBridgeState> controller =
        _stateController ??= _createStateController();
    return controller.stream;
  }

  StreamController<DVAIBridgeState> _createStateController() {
    late final StreamController<DVAIBridgeState> controller;
    controller = StreamController<DVAIBridgeState>.broadcast(
      onListen: () {
        _ensureProgressSubscription();
        _emitLatestState(controller);
        unawaited(_bootstrapState(controller));
      },
      onCancel: () {
        if (!controller.hasListener) {
          // No more listeners; leave the controller open but keep the
          // progress subscription alive so future `listen()` calls see
          // the most recent state via _emitLatestState.
        }
      },
    );
    return controller;
  }

  void _ensureProgressSubscription() {
    if (_progressSubscription != null) {
      return;
    }
    _progressSubscription = progressStream.listen(_handleProgress);
  }

  Future<void> _bootstrapState(
      StreamController<DVAIBridgeState> controller) async {
    try {
      final StatusInfo info = await status();
      final DVAIBridgeState next = DVAIBridgeState(
        isReady: info.running,
        baseUrl: info.baseUrl,
        port: info.port,
        backend: info.backend,
        modelId: info.modelId,
        lastProgress: _latestState.lastProgress,
        lastError: _latestState.lastError,
      );
      _latestState = next;
      if (!controller.isClosed) {
        controller.add(next);
      }
    } on DVAIBridgeError catch (err) {
      final DVAIBridgeState next = _latestState.copyWith(lastError: err);
      _latestState = next;
      if (!controller.isClosed) {
        controller.add(next);
      }
    }
  }

  void _emitLatestState(StreamController<DVAIBridgeState> controller) {
    if (!controller.isClosed) {
      controller.add(_latestState);
    }
  }

  void _handleProgress(ProgressEvent event) {
    final DVAIBridgeState previous = _latestState;
    DVAIBridgeState next = previous.copyWith(lastProgress: event);
    if (event.kind == ProgressKind.completed &&
        event.phase == ProgressPhase.start) {
      // Refresh the state from the native side once the bridge reports a
      // completed start; the BoundServer details land via status().
      unawaited(_refreshOnReady());
    } else if (event.kind == ProgressKind.completed &&
        event.phase == ProgressPhase.stop) {
      next = DVAIBridgeState(
        isReady: false,
        lastProgress: event,
        lastError: previous.lastError,
      );
    } else if (event.kind == ProgressKind.failed &&
        event.phase == ProgressPhase.start) {
      next = DVAIBridgeState(
        isReady: false,
        lastProgress: event,
        lastError: event.errorMessage == null
            ? const DVAIBridgeError.backendError('start failed')
            : DVAIBridgeError.backendError(event.errorMessage!),
      );
    }
    _latestState = next;
    final StreamController<DVAIBridgeState>? controller = _stateController;
    if (controller != null && !controller.isClosed) {
      controller.add(next);
    }
  }

  Future<void> _refreshOnReady() async {
    try {
      final StatusInfo info = await status();
      final DVAIBridgeState next = DVAIBridgeState(
        isReady: info.running,
        baseUrl: info.baseUrl,
        port: info.port,
        backend: info.backend,
        modelId: info.modelId,
        lastProgress: _latestState.lastProgress,
        lastError: _latestState.lastError,
      );
      _latestState = next;
      final StreamController<DVAIBridgeState>? controller = _stateController;
      if (controller != null && !controller.isClosed) {
        controller.add(next);
      }
    } on DVAIBridgeError catch (err) {
      final DVAIBridgeState next = _latestState.copyWith(lastError: err);
      _latestState = next;
      final StreamController<DVAIBridgeState>? controller = _stateController;
      if (controller != null && !controller.isClosed) {
        controller.add(next);
      }
    }
  }

  void _assertBackendAvailable(BackendKind backend) {
    if (_platform.isAndroid && _iosOnly.contains(backend)) {
      throw DVAIBridgeError.backendUnavailable(
        backend: backend,
        reason:
            'Backend "${backend.wireValue}" is iOS-only and is not available on Android.',
      );
    }
    if (_platform.isIOS && _androidOnly.contains(backend)) {
      throw DVAIBridgeError.backendUnavailable(
        backend: backend,
        reason:
            'Backend "${backend.wireValue}" is Android-only and is not available on iOS.',
      );
    }
    if (!_platform.isIOS && !_platform.isAndroid) {
      throw DVAIBridgeError.backendUnavailable(
        backend: backend,
        reason:
            'dvai_bridge supports only iOS and Android. Web / desktop are out of scope for v2.3.',
      );
    }
  }

  /// Tear down the singleton's internal subscriptions. Rarely useful in
  /// app code (the singleton lives for the process lifetime); exists for
  /// unit tests that want a clean slate between assertions.
  @visibleForTesting
  Future<void> dispose() async {
    await _progressSubscription?.cancel();
    _progressSubscription = null;
    await _stateController?.close();
    _stateController = null;
    _progressStream = null;
    _pairingRequestsStream = null;
    _latestState = DVAIBridgeState.idle;
  }

  /// The current cached state. Exposed for tests; consumers should listen
  /// to [stateStream] instead.
  @visibleForTesting
  DVAIBridgeState get debugLatestState => _latestState;
}

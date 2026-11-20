// Public entry point for the `dvai_bridge` Flutter plugin.
//
// Re-exports the hand-written facade + types. The Pigeon-generated wire
// types in `src/messages.g.dart` are intentionally NOT re-exported — the
// hand-written `BoundServer` / `StartOptions` / `StatusInfo` /
// `DownloadOptions` / `DownloadResult` shapes (in `src/types.dart`) are
// what consumers depend on.

export 'src/dvai_bridge.dart' show DVAIBridge;
export 'src/errors.dart'
    show
        AlreadyStartedError,
        BackendErrorError,
        BackendUnavailableError,
        ChecksumMismatchError,
        ConfigurationInvalidError,
        DVAIBridgeError,
        DVAIBridgeErrorKind,
        DownloadFailedError,
        ModelLoadFailedError,
        NotStartedError;
export 'src/offload.dart'
    show OffloadConfig, PairingRequest, Peer, PeerVia;
export 'src/progress.dart'
    show DVAIBridgeState, ProgressEvent, ProgressKind, ProgressPhase;
export 'src/types.dart'
    show
        BackendKind,
        BoundServer,
        CorsOrigin,
        CpuClass,
        DeviceCapabilityHints,
        DownloadOptions,
        DownloadResult,
        GpuClass,
        HardwareAssessment,
        LogLevel,
        PrecheckMode,
        StartOptions,
        StatusInfo;

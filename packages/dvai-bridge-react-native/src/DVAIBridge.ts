import { NativeEventEmitter, NativeModules, Platform } from "react-native";

import NativeDVAIBridge from "./NativeDVAIBridge";
import { DVAIBridgeError } from "./errors";
import type {
  BackendKind,
  BoundServer,
  CpuClass,
  DownloadOptions,
  DownloadResult,
  GpuClass,
  HardwareAssessment,
  PairingRequest,
  PairingSubscription,
  ProgressEvent,
  ProgressSubscription,
  StartOptions,
  StatusInfo,
} from "./types";

/** BackendKind values that only run on iOS. Selecting one on Android throws eagerly. */
const IOS_ONLY_BACKENDS: ReadonlySet<BackendKind> = new Set<BackendKind>([
  "foundation",
  "coreml",
  "mlx",
]);

/** BackendKind values that only run on Android. Selecting one on iOS throws eagerly. */
const ANDROID_ONLY_BACKENDS: ReadonlySet<BackendKind> = new Set<BackendKind>([
  "mediapipe",
  "litert",
]);

const PROGRESS_EVENT_NAME = "DVAIBridgeProgress";
const PAIRING_REQUEST_EVENT_NAME = "DVAIBridgePairingRequest";

/**
 * Lazy `NativeEventEmitter` instance scoped to the `DVAIBridge` module.
 *
 * Constructing the emitter requires a `NativeModule` reference. Under
 * Bridgeless mode (RN ≥ 0.74 default) the TurboModule itself satisfies
 * that. Under the legacy bridge we fall back to `NativeModules.DVAIBridge`.
 * Either way, the emitter is created only on first subscription so unit
 * tests that don't touch progress events don't pay for it.
 */
let progressEmitter: NativeEventEmitter | undefined;

function getProgressEmitter(): NativeEventEmitter {
  if (!progressEmitter) {
    // RN's NativeEventEmitter accepts a NativeModule with the addListener /
    // removeListeners methods. The TurboModule satisfies this contract.
    // Cast via `unknown` so the structural mismatch with the legacy
    // NativeModules type doesn't bleed into the public surface.
    type EmitterCtorArg = ConstructorParameters<typeof NativeEventEmitter>[0];
    const moduleRef =
      ((NativeDVAIBridge as unknown) as EmitterCtorArg) ||
      ((NativeModules.DVAIBridge as unknown) as EmitterCtorArg);
    progressEmitter = new NativeEventEmitter(moduleRef);
  }
  return progressEmitter;
}

/** Validate that the requested backend is supported on the running platform. */
function assertBackendAvailable(backend: BackendKind): void {
  if (Platform.OS === "android" && IOS_ONLY_BACKENDS.has(backend)) {
    throw new DVAIBridgeError(
      "backendUnavailable",
      `Backend "${backend}" is iOS-only and is not available on Android.`,
    );
  }
  if (Platform.OS === "ios" && ANDROID_ONLY_BACKENDS.has(backend)) {
    throw new DVAIBridgeError(
      "backendUnavailable",
      `Backend "${backend}" is Android-only and is not available on iOS.`,
    );
  }
  if (Platform.OS !== "ios" && Platform.OS !== "android") {
    throw new DVAIBridgeError(
      "backendUnavailable",
      `@dvai-bridge/react-native does not support platform "${Platform.OS}". iOS or Android only.`,
    );
  }
}

/** Coerce an unknown TurboModule result into a strongly-typed `BoundServer`. */
function coerceBoundServer(value: unknown): BoundServer {
  if (!value || typeof value !== "object") {
    throw new DVAIBridgeError(
      "backendError",
      "Native start() returned a non-object payload.",
    );
  }
  const v = value as Record<string, unknown>;
  const baseUrl = typeof v.baseUrl === "string" ? v.baseUrl : undefined;
  const port = typeof v.port === "number" ? v.port : undefined;
  const backend = typeof v.backend === "string" ? (v.backend as BackendKind) : undefined;
  const modelId = typeof v.modelId === "string" ? v.modelId : "";

  if (!baseUrl || port === undefined || !backend) {
    throw new DVAIBridgeError(
      "backendError",
      `Native start() returned malformed BoundServer: ${JSON.stringify(v)}`,
    );
  }
  return { baseUrl, port, backend, modelId };
}

/** Coerce an unknown TurboModule result into a strongly-typed `StatusInfo`. */
function coerceStatus(value: unknown): StatusInfo {
  if (!value || typeof value !== "object") {
    return { running: false };
  }
  const v = value as Record<string, unknown>;
  return {
    running: v.running === true,
    baseUrl: typeof v.baseUrl === "string" ? v.baseUrl : undefined,
    port: typeof v.port === "number" ? v.port : undefined,
    backend: typeof v.backend === "string" ? (v.backend as BackendKind) : undefined,
    modelId: typeof v.modelId === "string" ? v.modelId : undefined,
  };
}

/** Coerce an unknown TurboModule result into a strongly-typed `DownloadResult`. */
function coerceDownloadResult(value: unknown): DownloadResult {
  if (!value || typeof value !== "object") {
    throw new DVAIBridgeError(
      "downloadFailed",
      "Native downloadModel() returned a non-object payload.",
    );
  }
  const v = value as Record<string, unknown>;
  const path = typeof v.path === "string" ? v.path : undefined;
  if (!path) {
    throw new DVAIBridgeError(
      "downloadFailed",
      `Native downloadModel() returned malformed DownloadResult: ${JSON.stringify(v)}`,
    );
  }
  return {
    path,
    sha256: typeof v.sha256 === "string" ? v.sha256 : "",
    sizeBytes: typeof v.sizeBytes === "number" ? v.sizeBytes : 0,
    cached: typeof v.cached === "boolean" ? v.cached : undefined,
  };
}

/** Coerce an unknown TurboModule result into a `HardwareAssessment`. */
function coerceHardwareAssessment(value: unknown): HardwareAssessment {
  if (!value || typeof value !== "object") {
    throw new DVAIBridgeError(
      "configurationInvalid",
      "Native assessHardware() returned a non-object payload.",
    );
  }
  const v = value as Record<string, unknown>;
  const mode = typeof v.mode === "string" ? v.mode : "";
  if (mode !== "ok" && mode !== "offload-only" && mode !== "too-weak") {
    throw new DVAIBridgeError(
      "configurationInvalid",
      `Native assessHardware() returned an unknown mode: ${JSON.stringify(v.mode)}`,
    );
  }
  const hintsValue = (v.hints && typeof v.hints === "object") ? v.hints as Record<string, unknown> : {};
  return {
    mode,
    tokPerSec: typeof v.tokPerSec === "number" ? v.tokPerSec : 0,
    reason: typeof v.reason === "string" ? v.reason : "",
    hints: {
      hasNpu: typeof hintsValue.hasNpu === "boolean" ? hintsValue.hasNpu : false,
      ramGb: typeof hintsValue.ramGb === "number" ? hintsValue.ramGb : 0,
      gpuClass: (typeof hintsValue.gpuClass === "string"
        ? (hintsValue.gpuClass as GpuClass)
        : "integrated"),
      cpuClass: (typeof hintsValue.cpuClass === "string"
        ? (hintsValue.cpuClass as CpuClass)
        : "mid"),
    },
  };
}

/**
 * Public TS facade over the `NativeDVAIBridge` TurboModule. Mirrors the
 * iOS `DVAIBridge.shared` actor and the Android `DVAIBridge` singleton 1:1
 * in surface.
 *
 * Lifecycle:
 *
 * ```ts
 * const server = await DVAIBridge.start({
 *   backend: "auto",
 *   modelPath: "/path/to/Llama-3.2-1B-Instruct.Q4_K_M.gguf",
 * });
 * console.log(server.baseUrl); // "http://127.0.0.1:38883/v1"
 *
 * // … point any OpenAI-compatible RN HTTP client at server.baseUrl …
 *
 * await DVAIBridge.stop();
 * ```
 */
export const DVAIBridge = {
  /**
   * Start the embedded OpenAI-compatible HTTP server with the chosen
   * backend. Resolves with a {@link BoundServer} once the server is
   * listening; rejects with a {@link DVAIBridgeError} otherwise.
   */
  async start(opts: StartOptions): Promise<BoundServer> {
    assertBackendAvailable(opts.backend);
    try {
      const result = await NativeDVAIBridge.startBridge(opts);
      return coerceBoundServer(result);
    } catch (err) {
      throw DVAIBridgeError.fromNative(err);
    }
  },

  /**
   * Stop the active backend. Idempotent — calling when nothing is running
   * resolves cleanly.
   */
  async stop(): Promise<void> {
    try {
      await NativeDVAIBridge.stopBridge();
    } catch (err) {
      throw DVAIBridgeError.fromNative(err);
    }
  },

  /** Read the current bridge status. */
  async status(): Promise<StatusInfo> {
    try {
      const result = await NativeDVAIBridge.status();
      return coerceStatus(result);
    } catch (err) {
      throw DVAIBridgeError.fromNative(err);
    }
  },

  /**
   * v3.2 — pre-init hardware assessment.
   *
   * Returns a JSON-shaped {@link HardwareAssessment}. The SDK itself
   * never shows UI for hardware decisions — consumer apps call this
   * before {@link start} and decide their own UX based on
   * `result.mode`:
   *
   *  - `"ok"`           → call {@link start} normally.
   *  - `"offload-only"` → call {@link start}; SDK will skip the model
   *                       load and route every request to a paired
   *                       peer.
   *  - `"too-weak"`     → consumer typically bails rather than calling
   *                       {@link start}; if you do call it anyway, the
   *                       SDK enters offload-only mode silently.
   *
   * Defaults match the native sides (3.0 / 10.0 tok/s). Pass overrides
   * matching your `OffloadConfig` if you've customized.
   */
  async assessHardware(
    hardwareMinimum: number = 3.0,
    minLocalCapability: number = 10.0,
  ): Promise<HardwareAssessment> {
    try {
      const result = await NativeDVAIBridge.assessHardware(
        hardwareMinimum,
        minLocalCapability,
      );
      return coerceHardwareAssessment(result);
    } catch (err) {
      throw DVAIBridgeError.fromNative(err);
    }
  },

  /**
   * Download a model file with sha-256 verification. Resolves with the
   * cached file path on success.
   */
  async downloadModel(opts: DownloadOptions): Promise<DownloadResult> {
    try {
      const result = await NativeDVAIBridge.downloadModel(opts);
      return coerceDownloadResult(result);
    } catch (err) {
      throw DVAIBridgeError.fromNative(err);
    }
  },

  /**
   * Subscribe to lifecycle progress events emitted during `start()` /
   * `stop()` / `downloadModel()` calls. Returns a subscription handle
   * with a `remove()` method.
   *
   * Both iOS and Android emit the same JSON shape (see
   * {@link ProgressEvent}); the listener is invoked on the JS thread.
   */
  addProgressListener(
    listener: (event: ProgressEvent) => void,
  ): ProgressSubscription {
    const emitter = getProgressEmitter();
    const sub = emitter.addListener(PROGRESS_EVENT_NAME, listener);
    return {
      remove() {
        sub.remove();
      },
    };
  },

  /**
   * Detach a previously-registered progress listener by reference. Most
   * callers should hold the {@link ProgressSubscription} returned from
   * {@link addProgressListener} and call `.remove()` instead — this method
   * exists for parity with the native SDKs.
   */
  removeProgressListener(subscription: ProgressSubscription): void {
    subscription.remove();
  },

  /**
   * v3.0+ — distributed inference. Subscribe to one of the bridge's
   * named event channels:
   *
   *  - `"pairingRequest"`: emitted when an inbound peer requests pairing.
   *    The handler receives a {@link PairingRequest}; respond via
   *    {@link respondToPairing}. Default behaviour without a listener is
   *    to deny inbound pairing requests.
   *
   * The function is overloaded so additional event names can be added in
   * future releases without breaking the type signature for existing
   * consumers.
   */
  addListener(
    eventName: "pairingRequest",
    listener: (req: PairingRequest) => void,
  ): PairingSubscription {
    if (eventName !== "pairingRequest") {
      // Defensive: keep the wire-channel surface explicit so a future
      // typo in `eventName` fails fast in dev rather than silently no-op.
      throw new DVAIBridgeError(
        "configurationInvalid",
        `DVAIBridge.addListener: unknown event name "${eventName}". ` +
          `Valid event names: "pairingRequest".`,
      );
    }
    const emitter = getProgressEmitter();
    const sub = emitter.addListener(
      PAIRING_REQUEST_EVENT_NAME,
      listener as (event: unknown) => void,
    );
    return {
      remove() {
        sub.remove();
      },
    };
  },

  /**
   * v3.0+ — distributed inference. Resolve a pending {@link PairingRequest}
   * received via the `"pairingRequest"` event. Pass the request `id` and
   * the user's decision; the native side records the decision and either
   * lets the pairing proceed or rejects it.
   *
   * Idempotent — responding twice to the same `requestId` resolves
   * cleanly on subsequent calls.
   */
  async respondToPairing(requestId: string, approved: boolean): Promise<void> {
    try {
      await NativeDVAIBridge.respondToPairing(requestId, approved);
    } catch (err) {
      throw DVAIBridgeError.fromNative(err);
    }
  },

  /** Internal helper exposed for unit tests; not part of the public API. */
  _internalProgressEventName: PROGRESS_EVENT_NAME,
  /** Internal helper exposed for unit tests; not part of the public API. */
  _internalPairingRequestEventName: PAIRING_REQUEST_EVENT_NAME,
} as const;

export type {
  BoundServer,
  DownloadOptions,
  DownloadResult,
  PairingRequest,
  PairingSubscription,
  ProgressEvent,
  ProgressSubscription,
  StartOptions,
  StatusInfo,
};

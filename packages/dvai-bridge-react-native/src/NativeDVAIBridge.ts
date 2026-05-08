import type { TurboModule } from "react-native";
import { TurboModuleRegistry } from "react-native";

/**
 * TurboModule spec for the `@dvai-bridge/react-native` native bridge.
 *
 * Both iOS (Swift) and Android (Kotlin) bridge implementations conform to
 * this spec. RN codegen consumes this file at `pod install` / Gradle sync
 * to emit the C++ TurboModule stubs and the platform-side protocol /
 * abstract-class glue. Generated output is gitignored and not committed.
 *
 * `Object` (mapped to `NSDictionary` / `ReadableMap`) is used for the
 * StartOptions / BoundServer / DownloadOptions / DownloadResult payloads
 * because RN codegen lacks first-class support for nested optional unions
 * (CORS shape, BackendKind union) at the TurboModule boundary. The TS
 * facade in `DVAIBridge.ts` provides the strong typing on the JS side.
 *
 * Progress events are dispatched on the `"DVAIBridgeProgress"` channel via
 * `RCTEventEmitter` (iOS) and `RCTDeviceEventEmitter` (Android). The
 * `addListener` / `removeListeners` methods below are required by
 * `NativeEventEmitter` to satisfy RN's auto-management of event-emitter
 * subscriptions on the JS side; they're intentionally no-ops on the native
 * side beyond the standard counter bookkeeping.
 */
export interface Spec extends TurboModule {
  /**
   * Start the embedded HTTP server with the chosen backend. Returns a
   * `BoundServer` shape: `{ baseUrl, port, backend, modelId }`.
   *
   * @throws an error whose `code` is one of the
   *         `DVAIBridgeErrorKind` strings ("alreadyStarted",
   *         "backendUnavailable", "modelLoadFailed", …) when the native
   *         side rejects the call. The TS facade rewraps as
   *         `DVAIBridgeError`.
   */
  startBridge(opts: Object): Promise<Object>;

  /** Stop the active backend. Idempotent — resolves cleanly when nothing is running. */
  stopBridge(): Promise<void>;

  /**
   * Synchronous-style status snapshot: `{ running, baseUrl?, port?,
   * backend?, modelId? }`. Promise-based because TurboModule sync calls
   * are bridgeless-only and we want compatibility with both old/new arch
   * RN flavors.
   */
  status(): Promise<Object>;

  /** Download a model file with sha-256 verification. Returns `{ path, sha256, sizeBytes, cached? }`. */
  downloadModel(opts: Object): Promise<Object>;

  /**
   * v3.2 — pre-init hardware assessment.
   *
   * Returns a JSON-shaped value: `{ mode, tokPerSec, reason, hints }`
   * mirroring the Android DVAIBridge.assessHardware() and iOS
   * DVAIBridge.shared.assessHardware() return shapes. Lets the
   * consumer app decide whether to call `start` and what UI to show
   * if the device is too weak — the SDK never shows UI itself.
   *
   * Both `hardwareMinimum` and `minLocalCapability` default to the
   * same values as the native sides (3.0 / 10.0 tok/s). Pass
   * overrides matching your `OffloadConfig` if you've customized.
   */
  assessHardware(hardwareMinimum: number, minLocalCapability: number): Promise<Object>;

  /**
   * v3.0+ — Phase 3 distributed inference.
   *
   * Respond to a pending pairing request emitted via the
   * `"DVAIBridgePairingRequest"` event channel. `requestId` matches the
   * `id` field of the {@link PairingRequest} payload. `approved=true`
   * tells the native side to accept the inbound peer; `false` rejects.
   *
   * Resolves once the native side records the decision; idempotent for
   * already-resolved requests (those resolve cleanly without effect).
   */
  respondToPairing(requestId: string, approved: boolean): Promise<void>;

  // NativeEventEmitter housekeeping — required for `DVAIBridgeProgress`
  // and `DVAIBridgePairingRequest` events. RN's NativeEventEmitter calls
  // these to track subscriber count.
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>("DVAIBridge");

/**
 * Public entry point for `@dvai-bridge/react-native`.
 *
 *  - `DVAIBridge`: the TS facade (`start` / `stop` / `status` / `downloadModel` / progress listeners).
 *  - `BackendKind`: union of every backend supported by either platform.
 *  - `DVAIBridgeError`: error class with stable `kind` discriminator.
 *  - `useDVAIBridgeState`: React hook returning a reactive {@link DVAIBridgeState}.
 *  - All public types (StartOptions, BoundServer, ProgressEvent, …).
 */
export { DVAIBridge } from "./DVAIBridge";
export { DVAIBridgeError } from "./errors";
export { BackendKind } from "./types";
export type {
  BoundServer,
  CorsOrigin,
  DownloadOptions,
  DownloadResult,
  DVAIBridgeErrorKind,
  DVAIBridgeState,
  ProgressEvent,
  ProgressPhase,
  ProgressSubscription,
  StartOptions,
  StatusInfo,
} from "./types";
export { useDVAIBridgeState } from "./hooks/useDVAIBridgeState";

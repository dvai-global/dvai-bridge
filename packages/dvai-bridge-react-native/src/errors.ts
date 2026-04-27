import type { DVAIBridgeErrorKind } from "./types";

/**
 * The single error type thrown across the public TS surface. Mirrors iOS
 * `DVAIBridgeError` cases and Android `DVAIBridgeError` subclasses by
 * preserving a stable `kind` discriminator.
 *
 * Usage:
 *
 * ```ts
 * try {
 *   await DVAIBridge.start({ backend: "auto", modelPath: "..." });
 * } catch (err) {
 *   if (err instanceof DVAIBridgeError && err.kind === "backendUnavailable") {
 *     // Fall back to a different backend.
 *   }
 *   throw err;
 * }
 * ```
 *
 * The native modules throw a matching error from Swift / Kotlin; the bridge
 * impl catches and re-throws as a `DVAIBridgeError` so the JS side sees a
 * consistent shape regardless of which platform raised the failure.
 */
export class DVAIBridgeError extends Error {
  /** Stable error code matching the iOS / Android case names. */
  public readonly kind: DVAIBridgeErrorKind;
  /** Optional underlying error (e.g. for HTTP failures during download). */
  public override readonly cause?: unknown;

  constructor(kind: DVAIBridgeErrorKind, message: string, cause?: unknown) {
    super(message);
    this.name = "DVAIBridgeError";
    this.kind = kind;
    this.cause = cause;
    // Restore prototype chain for downlevel-emit ES5 targets so
    // `err instanceof DVAIBridgeError` works as expected.
    Object.setPrototypeOf(this, DVAIBridgeError.prototype);
  }

  /**
   * Construct a {@link DVAIBridgeError} from a value caught at the native
   * boundary. RN's TurboModule rejection forwards an `Error`-shaped object
   * whose `code` property is the iOS / Android error kind. Fall back to
   * `"backendError"` when the kind isn't recognized.
   */
  static fromNative(err: unknown): DVAIBridgeError {
    if (err instanceof DVAIBridgeError) return err;
    if (err && typeof err === "object") {
      const e = err as { code?: unknown; message?: unknown; userInfo?: { kind?: unknown } };
      const kind = (e.userInfo?.kind ?? e.code) as DVAIBridgeErrorKind | undefined;
      const message = typeof e.message === "string" ? e.message : "Unknown native error";
      if (kind && KNOWN_KINDS.has(kind)) {
        return new DVAIBridgeError(kind, message, err);
      }
      return new DVAIBridgeError("backendError", message, err);
    }
    return new DVAIBridgeError("backendError", String(err));
  }
}

const KNOWN_KINDS: ReadonlySet<DVAIBridgeErrorKind> = new Set<DVAIBridgeErrorKind>([
  "alreadyStarted",
  "notStarted",
  "configurationInvalid",
  "modelLoadFailed",
  "backendUnavailable",
  "backendError",
  "checksumMismatch",
  "downloadFailed",
]);

export type {
  Transport,
  TransportKind,
  TransportStartResult,
  HttpTransportOptions,
  MswTransportOptions,
} from "./types.js";
export { MswTransport } from "./msw.js";
export { HttpTransport } from "./http.js";
export { BASE_PORT, MAX_PORT_ATTEMPTS, tryBind } from "./port-fallback.js";

export interface SelectTransportInput {
  /** Raw config: "auto" | "msw" | "http" | "none", or undefined. */
  transport?: "auto" | "msw" | "http" | "none";
  /** Back-compat signal: "" disables transport when transport is not explicit. */
  serviceWorkerUrl?: string;
}

/** Resolve "auto" based on the runtime environment. */
export function selectTransport(
  input: SelectTransportInput,
): "msw" | "http" | "none" {
  // Back-compat escape hatch: empty serviceWorkerUrl with no explicit transport → none
  if (input.serviceWorkerUrl === "" && input.transport == null) return "none";
  const requested = input.transport ?? "auto";
  if (requested !== "auto") return requested;
  if (isBrowserLike()) return "msw";
  if (isNode()) return "http";
  return "none";
}

function isBrowserLike(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof document !== "undefined" &&
    typeof navigator !== "undefined" &&
    typeof (navigator as any).serviceWorker !== "undefined"
  );
}

function isNode(): boolean {
  return (
    typeof process !== "undefined" &&
    process.versions != null &&
    process.versions.node != null
  );
}

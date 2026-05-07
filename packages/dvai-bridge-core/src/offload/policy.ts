/**
 * Per-request offload policy parsing. Reads X-DVAI-Offload header,
 * defaults to "prefer".
 */

import type { OffloadHeader } from "./types.js";

const VALID: ReadonlySet<OffloadHeader> = new Set(["never", "prefer", "require"]);

export function parseOffloadHeader(headers: Headers | Record<string, string | undefined>): OffloadHeader {
  let raw: string | null | undefined;
  if (headers instanceof Headers) {
    raw = headers.get("x-dvai-offload");
  } else {
    // Case-insensitive lookup for the plain-object case.
    for (const [k, v] of Object.entries(headers)) {
      if (k.toLowerCase() === "x-dvai-offload") {
        raw = v;
        break;
      }
    }
  }
  if (!raw) return "prefer";
  const lc = raw.toLowerCase().trim() as OffloadHeader;
  return VALID.has(lc) ? lc : "prefer";
}

/**
 * Phase 3 — QR-code utilities (Task 7).
 *
 * QR *generation* lives here (the source device builds the QR payload
 * from the rendezvous session's session-created reply). QR *scanning*
 * is the host app's responsibility — camera UI is platform-specific
 * (AVFoundation on iOS, CameraX on Android, getUserMedia + a JS QR
 * decoder in the browser, etc.). The library exposes
 * `dvai.completePairFromQrPayload(payload)` which the host calls
 * after their camera lib decodes the QR.
 */

import type { QrPayload } from "../rendezvous/types.js";
import { encodeBase64Url } from "../rendezvous/keys.js";

/**
 * Encode a QrPayload as the URL-safe base64 string the QR code
 * actually contains. Round-trips with `decodeQrPayload` from
 * rendezvous/client.ts.
 */
export function encodeQrPayload(payload: QrPayload): string {
  return encodeBase64Url(new TextEncoder().encode(JSON.stringify(payload)));
}

/**
 * Build a `dvai-bridge://pair?p=<base64payload>` deep-link URL.
 *
 * Apps with custom URL schemes can encode the QR as this URL form
 * (some QR scanners auto-launch the app on scan). Apps without a
 * custom scheme can stick with the bare base64 payload — both
 * round-trip via the same `decodeQrPayload`.
 */
export function buildPairUrl(payload: QrPayload, scheme = "dvai-bridge"): string {
  return `${scheme}://pair?p=${encodeQrPayload(payload)}`;
}

/** Extract the base64 payload from a `dvai-bridge://pair?p=...` URL. */
export function extractPayloadFromPairUrl(url: string): string {
  const match = url.match(/[?&]p=([A-Za-z0-9_-]+)/);
  if (!match) throw new Error("[DVAI/qr] no `p=` param in pair URL");
  return match[1];
}

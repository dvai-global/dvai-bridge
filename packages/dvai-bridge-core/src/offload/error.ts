/**
 * Constructs the structured `no_capable_device` HTTP error response.
 * Returned with HTTP 503 + Retry-After: 30. Body is OpenAI-error-shaped
 * so existing OpenAI clients surface it naturally.
 */

import type { Decision } from "./types.js";
import type { NoCapableDeviceErrorBody } from "./types.js";

export function buildNoCapableDeviceResponse(
  decision: Extract<Decision, { kind: "no_capable_device" }>,
  ctx: { rendezvousConfigured: boolean; pairedRemotePeers: number; requestId?: string; modelId: string },
): { status: number; headers: Record<string, string>; body: NoCapableDeviceErrorBody } {
  const message =
    `No device with capability ≥ ${decision.required} tok/s for model ` +
    `${ctx.modelId} was reachable. Local: ${decision.localCapability} tok/s; ` +
    `${decision.checked.length - 1} peer(s) checked.`;

  return {
    status: 503,
    headers: {
      "Content-Type": "application/json",
      "Retry-After": "30",
    },
    body: {
      error: {
        type: "no_capable_device",
        code: 503,
        message,
        checked: decision.checked,
        localCapability: decision.localCapability,
        requiredAtLeast: decision.required,
        rendezvousConfigured: ctx.rendezvousConfigured,
        pairedRemotePeers: ctx.pairedRemotePeers,
        requestId: ctx.requestId,
      },
    },
  };
}

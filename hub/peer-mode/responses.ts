/**
 * Hub-side 503 error-response builders for the chat-completions interceptor.
 *
 * Both responses mirror the rendezvous-side core lib's no_capable_device
 * pattern (packages/dvai-bridge-core/src/offload/error.ts):
 *   - HTTP 503
 *   - `Retry-After: 30` header (existing OpenAI clients surface this as a
 *     backoff hint via LangChain / Vercel AI SDK / Semantic Kernel)
 *   - OpenAI-error-shaped JSON body so downstream catches it naturally
 *
 * Extracted from server.ts so the interceptor's failure paths can be
 * tested in isolation without bringing up the JSON-RPC stdin loop.
 */

/** Default backoff hint in seconds. Same value as the core lib. */
export const HUB_503_RETRY_AFTER_SECONDS = 30;

/**
 * Build the 503 response returned when no available backend can serve
 * the requested model (substitution refused at the routing layer).
 */
export function buildNoCapableDeviceResponse(
  requestedModel: string,
  reason: string,
  detail?: unknown,
): Response {
  return Response.json(
    {
      error: {
        type: "no_capable_device",
        code: 503,
        message: `No backend can serve "${requestedModel}". Reason: ${reason}.`,
        ...(detail !== undefined ? { detail } : {}),
      },
    },
    {
      status: 503,
      headers: { "Retry-After": String(HUB_503_RETRY_AFTER_SECONDS) },
    },
  );
}

/**
 * Build the 503 response returned when routing picked an external engine
 * but the corresponding adapter is no longer registered with the bridge
 * (engine uninstalled / crashed between routing decision and dispatch).
 */
export function buildEngineAdapterNotFoundResponse(engine: string): Response {
  return Response.json(
    {
      error: {
        type: "engine_adapter_not_found",
        code: 503,
        message: `Adapter for engine "${engine}" is not available.`,
      },
    },
    {
      status: 503,
      headers: { "Retry-After": String(HUB_503_RETRY_AFTER_SECONDS) },
    },
  );
}

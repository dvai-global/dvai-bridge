/**
 * v3.2 — auto-wired offload forwarder.
 *
 * Returns a `chatCompletionInterceptor` (the same shape that the Hub
 * uses for its substitution-policy hook) which:
 *
 *   1. On every /v1/chat/completions request, runs `decide()` to pick
 *      a route.
 *   2. If decide → "offload": calls `proxyToPeer` and returns a
 *      Response with the peer's reply.
 *   3. If decide → "no_capable_device": returns a structured 503
 *      using `buildNoCapableDeviceResponse()`.
 *   4. If decide → "local": returns null. The default handler runs:
 *        - When the local backend exists, it serves the request.
 *        - When the SDK is in offload-only mode (no backend), the
 *          default handler returns 503 itself ("not initialized").
 *          That second 503 indicates a peer was claimed available
 *          but isn't usable for this model — operationally rare.
 *
 * The forwarder reads dynamic state (current peers, current
 * capability score) every call so changes to either don't require
 * re-wiring. Pass dynamic getters in `opts`.
 */

import { decide } from "./decide.js";
import { buildNoCapableDeviceResponse } from "./error.js";
import { proxyToPeer } from "./proxy.js";
import { parseOffloadHeader } from "./policy.js";
import type { OffloadConfig, OffloadHeader } from "./types.js";
import type { Peer } from "../discovery/types.js";
import type { HandlerContext } from "../handlers/context.js";

export interface ForwarderOptions {
  /** Static OffloadConfig (the one supplied to the SDK). */
  config: OffloadConfig;
  /** Live snapshot of discovered peers. Re-read on each request. */
  getPeers: () => Peer[];
  /** Live capability score for `modelId` on this device. */
  getLocalCapability: (modelId: string) => number;
  /** When true, every "local" decision is forced to a 503 because
   *  no local backend exists to serve it (offload-only mode). */
  offloadOnlyMode: boolean;
}

type Interceptor = NonNullable<HandlerContext["chatCompletionInterceptor"]>;

export function buildOffloadInterceptor(opts: ForwarderOptions): Interceptor {
  return async function offloadInterceptor(
    body: any,
    ctx: HandlerContext,
    headers?: Record<string, string>,
  ): Promise<Response | null> {
    if (!opts.config.enabled) return null;

    // Per-request override (X-DVAI-Offload header). Defaults to "prefer".
    const headerValue = readOffloadHeader(headers);

    const peers = opts.getPeers();
    const modelId = ctx.modelId;
    const localCapability = opts.getLocalCapability(modelId);

    const decision = decide({
      config: opts.config,
      modelId,
      localCapability,
      peers,
      header: headerValue,
    });

    if (decision.kind === "local") {
      // In offload-only mode the default handler will 503 because
      // ctx.backend is null. We could short-circuit here with a
      // friendlier message, but returning null preserves the
      // backend-not-initialized error path the existing code already
      // handles.
      if (opts.offloadOnlyMode) {
        // Offload-only + decide-said-local: typically means
        // header=never (caller insisted on local). Surface that
        // explicitly so the caller knows their override was the cause.
        return jsonResponse(503, {
          error: {
            type: "no_local_backend",
            code: 503,
            message:
              "DVAI is running in offload-only mode (device below " +
              "minLocalCapability) and the request requested local " +
              "execution (X-DVAI-Offload: never). Either drop the " +
              "header or route to a peer.",
          },
        });
      }
      return null;
    }

    if (decision.kind === "offload") {
      // Forward to the peer. Streaming is detected from the request body.
      const stream = body && typeof body === "object" && body.stream === true;
      try {
        const proxied = await proxyToPeer(decision.peer, {
          method: "POST",
          path: "/chat/completions",
          body,
          stream,
          headers: forwardableHeaders(headers),
        });

        // Best-effort callback (consumer-supplied diagnostics).
        try {
          opts.config.onOffload?.(decision.peer);
        } catch {
          // host-provided callback errors must not break the response
        }

        if (proxied.stream) {
          return new Response(proxied.stream, {
            status: proxied.status,
            headers: proxied.headers,
          });
        }
        return new Response(JSON.stringify(proxied.body), {
          status: proxied.status,
          headers: proxied.headers,
        });
      } catch (err) {
        // Proxy failed (peer unreachable, network drop, etc.). Surface
        // a 502 — the upstream peer was supposed to handle it but
        // didn't. Caller can retry; another peer might still be available.
        return jsonResponse(502, {
          error: {
            type: "peer_unreachable",
            code: 502,
            message: `Offload to peer ${decision.peer.deviceId} failed: ${
              err instanceof Error ? err.message : String(err)
            }`,
            peerId: decision.peer.deviceId,
          },
        });
      }
    }

    // decision.kind === "no_capable_device"
    const errResponse = buildNoCapableDeviceResponse(decision, {
      rendezvousConfigured: !!opts.config.rendezvousUrl,
      pairedRemotePeers: peers.filter((p) => p.via === "rendezvous").length,
      modelId,
    });
    return new Response(JSON.stringify(errResponse.body), {
      status: errResponse.status,
      headers: errResponse.headers,
    });
  };
}

function readOffloadHeader(
  headers?: Record<string, string>,
): OffloadHeader {
  if (!headers) return "prefer";
  return parseOffloadHeader(headers as Record<string, string | undefined>);
}

/** Strip hop-by-hop / problematic headers; keep auth-relevant ones. */
function forwardableHeaders(
  headers?: Record<string, string>,
): Record<string, string> {
  if (!headers) return {};
  const out: Record<string, string> = {};
  const drop = new Set([
    "host",
    "content-length",
    "connection",
    "keep-alive",
    "transfer-encoding",
  ]);
  for (const [k, v] of Object.entries(headers)) {
    if (drop.has(k.toLowerCase())) continue;
    out[k] = v;
  }
  return out;
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

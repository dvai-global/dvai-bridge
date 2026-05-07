/**
 * Phase 3 — `/v1/dvai/*` handlers.
 *
 * Hosted by the same in-process HTTP server (or MSW intercept in
 * browser) that already serves the OpenAI surface. Routes:
 *
 *   GET  /v1/dvai/health      — liveness, capacity, version
 *   GET  /v1/dvai/capability  — this device's capability map
 *   GET  /v1/dvai/peers       — discovered peer list
 *   POST /v1/dvai/probe       — manually trigger a capability probe
 *   POST /v1/dvai/handshake   — LAN-pairing handshake
 *   POST /v1/dvai/pair-qr     — start a rendezvous session, return QR payload
 *   POST /v1/dvai/pair-scan   — submit a scanned QR payload, complete the join
 *
 * These handlers are pure-ish — they take a context object with the
 * relevant collaborators (capability cache, discovery, pairing policy,
 * rendezvous client, etc.) and return JSON responses. Wired into the
 * core's existing handler pipeline by src/index.ts.
 */

import type { CapabilityCache, CapabilityScore, ProbableBackend } from "../../capability/index.js";
import { getCapability, probeAndCache, ensureDeviceId } from "../../capability/index.js";
import type { Peer, IDiscovery } from "../../discovery/index.js";
import type { PairingPolicy, IncomingHandshake } from "../../pairing/index.js";

export interface DvaiHandlerContext {
  /** Library SemVer — used in cache keys + responses. */
  libraryVersion: string;
  /** Currently-loaded model ID (for capability lookup). */
  currentModelId?: string;
  /** Capability cache. */
  capabilityCache: CapabilityCache;
  /** Backend reference for the probe endpoint. */
  backend?: ProbableBackend;
  /** Discovery layer. */
  discovery?: IDiscovery;
  /** Pairing policy. */
  pairingPolicy?: PairingPolicy;
  /** Server-uptime epoch. */
  startedAt: number;
}

/** Generic handler shape: takes parsed request body, returns JSON-stringifiable. */
export type DvaiHandler = (req: { body: unknown }) => Promise<{
  status: number;
  body: unknown;
}>;

/* -------------------------------------------------------------------------- */
/* Handlers                                                                    */
/* -------------------------------------------------------------------------- */

export function handleHealth(ctx: DvaiHandlerContext): DvaiHandler {
  return async () => ({
    status: 200,
    body: {
      status: "ok",
      version: ctx.libraryVersion,
      uptimeSec: Math.floor((Date.now() - ctx.startedAt) / 1000),
      currentModelId: ctx.currentModelId ?? null,
    },
  });
}

export function handleCapability(ctx: DvaiHandlerContext): DvaiHandler {
  return async () => {
    const all: CapabilityScore[] = await ctx.capabilityCache.list();
    return { status: 200, body: { scores: all } };
  };
}

export function handlePeers(ctx: DvaiHandlerContext): DvaiHandler {
  return async () => {
    const peers: Peer[] = ctx.discovery?.peers() ?? [];
    return { status: 200, body: { peers } };
  };
}

export function handleProbe(ctx: DvaiHandlerContext): DvaiHandler {
  return async (req) => {
    if (!ctx.backend) {
      return {
        status: 503,
        body: { error: { type: "no_backend", message: "no backend currently loaded" } },
      };
    }
    const body = (req.body ?? {}) as { modelId?: string };
    const modelId = body.modelId ?? ctx.currentModelId;
    if (!modelId) {
      return {
        status: 400,
        body: {
          error: {
            type: "missing_model_id",
            message: "supply `modelId` in request body or call after a model is loaded",
          },
        },
      };
    }
    const score = await probeAndCache({
      cache: ctx.capabilityCache,
      backend: ctx.backend,
      modelId,
      libraryVersion: ctx.libraryVersion,
    });
    return { status: 200, body: { score } };
  };
}

export function handleHandshake(ctx: DvaiHandlerContext): DvaiHandler {
  return async (req) => {
    if (!ctx.pairingPolicy) {
      return {
        status: 503,
        body: { error: { type: "pairing_disabled", message: "pairing not configured" } },
      };
    }
    const body = req.body as Partial<IncomingHandshake> | undefined;
    if (!body?.peerDeviceId || !body?.peerDeviceName) {
      return {
        status: 400,
        body: { error: { type: "malformed_handshake", message: "missing peerDeviceId / peerDeviceName" } },
      };
    }
    try {
      const pairing = await ctx.pairingPolicy.approveOrFetch({
        peerDeviceId: body.peerDeviceId,
        peerDeviceName: body.peerDeviceName,
        via: body.via ?? "lan-handshake",
        ...(body.appId !== undefined ? { appId: body.appId } : {}),
      });
      // v3.1 wire protocol: echo the pairing key in the response so
      // the requester can HMAC-sign subsequent calls. LAN trust model
      // — the response only crosses the same Wi-Fi the handshake did,
      // and the protocol is opt-in (offload.enabled defaults to false).
      // The rendezvous-QR flow uses ECDH key agreement instead and
      // doesn't reach this handler.
      return {
        status: 200,
        body: {
          paired: true,
          pairedAt: pairing.pairedAt,
          via: pairing.via,
          pairingKey: pairing.pairingKey,
          peerDeviceId: pairing.peerDeviceId,
        },
      };
    } catch (err) {
      return {
        status: 403,
        body: { error: { type: "pairing_denied", message: String(err) } },
      };
    }
  };
}

export function handlePairQr(ctx: DvaiHandlerContext): DvaiHandler {
  return async () => {
    // The actual rendezvous-WS dance lives in src/rendezvous/client.ts;
    // this endpoint is a thin shim that returns a 501 here in v3.0.0-rc1
    // because the in-DVAI integration (creating a session + holding it
    // open until the target scans) needs the per-platform glue from
    // Task 8 (per-SDK integration). The endpoint shape is locked in
    // for forward-compat; the implementation lights up in 8a–8f.
    return {
      status: 501,
      body: {
        error: {
          type: "not_implemented_yet",
          message:
            "POST /v1/dvai/pair-qr requires per-SDK integration (Task 8); " +
            "the rendezvous client surface (rendezvous/client.ts) is callable " +
            "directly until then.",
        },
      },
    };
  };
}

export function handlePairScan(ctx: DvaiHandlerContext): DvaiHandler {
  return async () => {
    return {
      status: 501,
      body: {
        error: {
          type: "not_implemented_yet",
          message: "POST /v1/dvai/pair-scan requires per-SDK integration (Task 8).",
        },
      },
    };
  };
}

/**
 * Build the route → handler map. The transport layer (src/transports/)
 * dispatches incoming requests to these.
 */
export function buildDvaiRoutes(
  ctx: DvaiHandlerContext,
): Record<string, DvaiHandler> {
  return {
    "GET /v1/dvai/health": handleHealth(ctx),
    "GET /v1/dvai/capability": handleCapability(ctx),
    "GET /v1/dvai/peers": handlePeers(ctx),
    "POST /v1/dvai/probe": handleProbe(ctx),
    "POST /v1/dvai/handshake": handleHandshake(ctx),
    "POST /v1/dvai/pair-qr": handlePairQr(ctx),
    "POST /v1/dvai/pair-scan": handlePairScan(ctx),
  };
}

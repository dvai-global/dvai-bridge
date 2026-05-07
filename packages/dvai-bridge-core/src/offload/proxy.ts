/**
 * Offload proxy. Given a Decision.offload, forward the OpenAI HTTP
 * request to the peer's baseUrl and stream the response back to the
 * caller.
 *
 * For LAN peers: direct HTTP. For rendezvous-paired peers: the same
 * HTTP shape but tunneled through the rendezvous WebSocket relay.
 * (Rendezvous tunneling is a v3.0+ extension; this initial impl
 * supports the LAN HTTP path; rendezvous support is wired in once
 * Task 5+6 land the handshake + endpoint glue.)
 */

import type { Peer } from "../discovery/types.js";

export interface ProxyRequest {
  method: "POST" | "GET";
  path: string;  // e.g. "/chat/completions"
  body?: unknown;
  headers?: Record<string, string>;
  /** Whether to expect SSE-style streaming response. */
  stream: boolean;
  /** Caller's AbortSignal — propagated to the upstream fetch. */
  signal?: AbortSignal;
}

export interface ProxyResponse {
  status: number;
  headers: Record<string, string>;
  /** For non-streaming: the parsed body. */
  body?: unknown;
  /** For streaming: a ReadableStream of SSE-format chunks. */
  stream?: ReadableStream<Uint8Array>;
}

/**
 * Proxy a single request to a peer. The peer's baseUrl is the OpenAI
 * v1 root (e.g. http://192.168.1.10:38883/v1).
 */
export async function proxyToPeer(
  peer: Peer,
  req: ProxyRequest,
): Promise<ProxyResponse> {
  if (peer.via === "rendezvous") {
    // TODO(v3.0): wire up the WebSocket relay path. For now, fall
    // through to direct HTTP if the peer also has a baseUrl (which
    // it shouldn't for pure-rendezvous peers; left as a guard).
    if (!peer.baseUrl || !peer.baseUrl.startsWith("http")) {
      throw new Error(
        "[DVAI/offload] rendezvous-paired peers require WebSocket relay " +
          "(not yet implemented in v3.0.0-rc1; expected in v3.0.0 final).",
      );
    }
  }

  const url = `${peer.baseUrl.replace(/\/$/, "")}${req.path}`;
  const upstreamHeaders: Record<string, string> = {
    "Content-Type": "application/json",
    "X-DVAI-Forwarded": "1",
    ...(req.headers ?? {}),
  };

  const response = await fetch(url, {
    method: req.method,
    headers: upstreamHeaders,
    body: req.body !== undefined ? JSON.stringify(req.body) : undefined,
    signal: req.signal,
  });

  const headers: Record<string, string> = {};
  response.headers.forEach((v, k) => {
    headers[k] = v;
  });

  if (req.stream && response.body) {
    return {
      status: response.status,
      headers,
      stream: response.body,
    };
  }

  return {
    status: response.status,
    headers,
    body: await response.json().catch(() => undefined),
  };
}

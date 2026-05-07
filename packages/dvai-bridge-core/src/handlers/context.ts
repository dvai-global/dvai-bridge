/**
 * Duck-typed backend contract consumed by the transport-agnostic handlers.
 * Both existing backends (WebLLMBackend, TransformersBackend) satisfy this
 * structurally without any backend changes.
 */
export interface BackendInterface {
  chatCompletion(body: any): Promise<any>;
  createStreamingResponse(body: any): ReadableStream<Uint8Array>;
  embedding?(inputs: string | string[]): Promise<number[][]>;
  /** WebLLM sets this on fatal errors; triggers recovery path. */
  lastFatalError?: unknown;
  clearFatalError?(): void;
}

/**
 * Per-request context passed to every handler. Built once by DVAI.initialize()
 * and reused for the lifetime of the transport; handler reads the fields on
 * each request so state updates on DVAI (e.g. backendInstance replaced during
 * recovery) are visible through the same reference.
 */
export interface HandlerContext {
  /** Active backend; null means "not initialized" → 503. */
  backend: BackendInterface | null;

  /**
   * Resolved backend kind. Used only for error messages and the model
   * echo in responses. Union widens as new backends are added in later
   * phases — handlers must NOT dispatch on this value; always duck-type
   * on backend methods instead.
   */
  resolvedBackend: "webllm" | "transformers" | "native";

  /** Model identifier echoed back in responses. */
  modelId: string;

  /**
   * Optional recovery hook. Handler awaits this before a retry when
   * backend.lastFatalError is set. DVAI owns the retry counter and
   * throws when exhausted; handler only awaits. Undefined → no recovery.
   */
  onRecovery?: () => Promise<void>;

  /**
   * Phase 3 — `/v1/dvai/*` route map populated when `offload.enabled`.
   * Late-bound (getter) so transports can read it per request even
   * though the routes are built after the transport starts. Undefined
   * when offload isn't enabled — transports return 404 in that case.
   */
  dvaiRoutes?: Record<string, import("./dvai/index.js").DvaiHandler>;

  /**
   * Phase 4 — first-chance hook for /v1/chat/completions. The Hub
   * uses this to inject substitution-policy + engine-bridge routing
   * before the default handler dispatches to the local backend.
   *
   * Return a Response → that's what the client gets.
   * Return null → fall through to the default backend path.
   *
   * Receives request headers (lower-cased keys) so the interceptor can
   * read v3.1 identity fields (X-DVAI-Peer-Device-Id, X-DVAI-App-Id,
   * X-DVAI-Nonce, X-DVAI-Signature) for HMAC verification + tenant
   * routing.
   *
   * Errors raised in the interceptor propagate to the standard error
   * response path in handleChatCompletion.
   */
  chatCompletionInterceptor?: (
    body: any,
    ctx: HandlerContext,
    headers?: Record<string, string>,
  ) => Promise<Response | null>;
}

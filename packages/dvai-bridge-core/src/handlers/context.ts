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
  resolvedBackend: "webllm" | "transformers";

  /** Model identifier echoed back in responses. */
  modelId: string;

  /**
   * Optional recovery hook. Handler awaits this before a retry when
   * backend.lastFatalError is set. DVAI owns the retry counter and
   * throws when exhausted; handler only awaits. Undefined → no recovery.
   */
  onRecovery?: () => Promise<void>;
}

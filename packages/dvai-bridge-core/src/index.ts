import { LicenseValidator } from "./license/index.js";
import type { LicenseStatus } from "./license/index.js";
import { type HandlerContext } from "./handlers/index.js";

// Re-export types from backends
export type { TransformersProgressInfo } from "./TransformersBackend.js";
export { detectWebGPU } from "./TransformersBackend.js";

// Re-export InitProgressReport from web-llm for backward compatibility
export type { InitProgressReport } from "@mlc-ai/web-llm";

// Re-export legacy helpers from the handlers module for backward compat.
// Existing tests/consumers import these from "@dvai-bridge/core".
export {
	chatToLegacyCompletion,
	legacyCompletionStreamAdapter,
} from "./handlers/completions.js";

// v3.1 — re-export HMAC primitives so consumers (the Hub, native SDKs,
// rendezvous clients) can compose + verify signed messages without
// reaching into deep package paths.
export {
	composeSignedMessage,
	verifyHmac,
	signHmac,
	generateNonce,
	generatePairingKey,
} from "./pairing/handshake.js";

export type BackendType = "webllm" | "transformers" | "native" | "auto";
export type DeviceType = "webgpu" | "cpu" | "auto";
export type {
	PipelineTask,
	CreatePipelineFn,
	PipelineCallable,
} from "./TransformersBackend.js";

export interface DVAIConfig {
	/** The model ID for web-llm backend. Default: "gemma-2-2b-it-q4f16_1-MLC" */
	modelId?: string;
	/**
	 * The backend engine to use. Default: "webllm". Set to "auto" to auto-detect.
	 * - "webllm"       → @mlc-ai/web-llm (browser, WebGPU)
	 * - "transformers" → @huggingface/transformers (browser or Node)
	 * - "native"       → node-llama-cpp (Node only; loads a GGUF file)
	 * - "auto"         → resolved at runtime
	 */
	backend?: BackendType;
	/** HuggingFace model ID for Transformers.js backend. Default: "onnx-community/gemma-3n-E2B-it-ONNX" */
	transformersModelId?: string;
	/** Pipeline task for Transformers.js (e.g. "text-generation", "text-to-image", "automatic-speech-recognition"). Default: "text-generation" */
	pipelineTask?: string;
	/** Device for Transformers.js - "webgpu", "cpu", or "auto" (detect). Default: "auto" */
	device?: DeviceType;
	/** Quantization for Transformers.js (e.g. "q4", "q8", "f16"). Default: undefined */
	dtype?: string;
	/** Generation timeout in ms. Default: 60000 (60s) */
	generationTimeout?: number;
	/** Maximum consecutive blank chunks before aborting stream (WebLLM). Default: 20 */
	maxBlankChunks?: number;
	/** Maximum auto-recovery retries on fatal WebLLM errors (blank output/timeout). Default: 2 */
	maxRetries?: number;
	/** Mock URL for MSW interception. Default: "https://api.openai.local/v1/chat/completions" */
	mockUrl?: string;
	/** Path to the MSW service worker script. Default: "/mockServiceWorker.js" */
	serviceWorkerUrl?: string;
	/** URL to the WebLLM worker script (for offloading inference). Default: "/dvai-webllm.worker.js" */
	webllmWorkerUrl?: string;
	/** URL to the Transformers.js worker script (for offloading inference). Default: "/dvai-transformers.worker.js" */
	transformersWorkerUrl?: string;
	/**
	 * Custom pipeline factory for Transformers.js backend.
	 * MAIN-THREAD ONLY — function closures don't cross the Worker boundary.
	 * When provided, replaces the default pipeline() call with your own
	 * model loading and inference logic. Must return a callable that accepts
	 * (messages, options) and returns [{ generated_text: string }].
	 *
	 * For multimodal models that should run in the worker (recommended),
	 * use the declarative `transformersModelClass` / `transformersProcessorClass`
	 * / `transformersDisableEncoders` config instead.
	 */
	createPipeline?: import("./TransformersBackend.js").CreatePipelineFn;
	/**
	 * Name of a transformers.js export to use as the model class (loaded via
	 * `ClassName.from_pretrained(modelId)`). Enables the declarative
	 * multimodal loader — works in the worker AND on main thread so the
	 * same config ships correctly regardless of path.
	 *
	 * Examples: "Gemma4ForConditionalGeneration", "LlavaForConditionalGeneration",
	 * "AutoModelForCausalLM". Leave unset to use the generic `pipeline()` factory.
	 */
	transformersModelClass?: string;
	/**
	 * Processor class name for the declarative loader. Default: "AutoProcessor".
	 * Only used when `transformersModelClass` is set.
	 */
	transformersProcessorClass?: string;
	/**
	 * Model submodule fields to null out after load, e.g. `["vision_encoder"]`
	 * for a voice-only host app using a multimodal checkpoint. Purely
	 * declarative — dvai-bridge walks the list and nulls each named field
	 * if present; unknown/absent names are silently ignored. Host apps
	 * control this based on their own criteria.
	 */
	transformersDisableEncoders?: string[];

	// --- Capacitor native runtime options (forwarded by CapacitorTransport) ---
	/** Path to the GGUF model file for the Capacitor llama backend. */
	nativeModelPath?: string;
	/** Number of GPU layers for the Capacitor llama backend (iOS Metal). Default: 99 (max) */
	nativeGpuLayers?: number;
	/** Number of CPU threads for the Capacitor llama backend. Default: 4 */
	nativeThreads?: number;
	/** Context window size for the Capacitor llama backend. Default: 2048 */
	nativeContextSize?: number;
	/**
	 * Initialize the Capacitor llama context in embedding mode. Required for
	 * `/v1/embeddings` to work natively. When true, the context should be a
	 * dedicated embedding model and will typically not be usable for
	 * chat/completion. Default: false.
	 */
	nativeEmbeddingMode?: boolean;

	/**
	 * Path (or fetchable URL) to your DVAI-Bridge license JWT file.
	 *
	 * Default behaviour when this is unset: the SDK looks for
	 * `dvai-license.jwt` at platform-conventional locations:
	 *   - Node: `process.cwd()/dvai-license.jwt` (and one level up for
	 *     monorepos)
	 *   - Browser / Capacitor: same-origin `/dvai-license.jwt`
	 *
	 * Override mechanisms in priority order:
	 *   1. `licenseToken` (below) — inline JWT string, highest priority
	 *   2. `licenseKeyPath` (this field) — explicit path or URL
	 *   3. `DVAI_LICENSE_PATH` env var
	 *   4. `DVAI_LICENSE_TOKEN` env var — inline JWT
	 *   5. Auto-discovery
	 *
	 * If no license is found OR validation fails, the SDK falls back to
	 * the free tier (with the "Powered by DVAI Bridge" attribution
	 * badge in browser/Capacitor contexts). The SDK never refuses to
	 * start because of a license problem — license issues surface as a
	 * `licenseStatus` value with `kind: "free-prod"` and a
	 * human-readable `reason`.
	 */
	licenseKeyPath?: string;

	/**
	 * Inline DVAI-Bridge license JWT (the full token string). Use this
	 * when you'd rather inject the license via env var / config than
	 * ship a file — typical in serverless / containerised deployments
	 * where filesystem state is awkward.
	 *
	 * If both `licenseToken` and `licenseKeyPath` are set, `licenseToken`
	 * wins.
	 */
	licenseToken?: string;
	/** Auto-initialize on creation (React/Vanilla). Default: true */
	autoInit?: boolean;

	/**
	 * Phase 3 (v3.0+) — distributed inference / device offload.
	 *
	 * If unset OR `enabled: false`, the library behaves exactly like
	 * v2.x: every request runs locally. When enabled, the library
	 * discovers peer devices on the LAN (via mDNS) and / or via a
	 * self-hosted rendezvous server (if `rendezvousUrl` is set), and
	 * routes inference requests to the most-capable peer when local
	 * tok/s falls below `minLocalCapability`.
	 *
	 * See `docs/guide/distributed-inference.md` for the full design,
	 * `docs/guide/self-hosting-rendezvous.md` for the rendezvous
	 * server self-hosting flow, and `src/offload/types.ts` for the
	 * full `OffloadConfig` shape.
	 */
	offload?: import("./offload/index.js").OffloadConfig;

	/**
	 * Which transport to use for the OpenAI-compatible surface.
	 * - "auto"      (default) → capacitor on Capacitor, msw in browser,
	 *                            http in Node, none in workers
	 * - "msw"       → force MSW (browser only; errors elsewhere)
	 * - "http"      → force HTTP server (Node only; errors elsewhere)
	 * - "capacitor" → force native Capacitor HTTP server (requires
	 *                  @dvai-bridge/capacitor + a Capacitor backend plugin)
	 * - "none"      → no transport; use dvai.chatCompletion() directly
	 */
	transport?: "auto" | "msw" | "http" | "none" | "capacitor";

	/** HTTP-only. Base port. Default: 38883. */
	httpBasePort?: number;

	/** HTTP-only. Max port-fallback attempts. Default: 16. */
	httpMaxPortAttempts?: number;

	/**
	 * HTTP-only. Network interface to bind. Default `127.0.0.1`
	 * (loopback only). Set to `0.0.0.0` for LAN-target deployments
	 * (the v3.1 Hub, native SDKs running in target mode) so peers on
	 * the same Wi-Fi can reach the embedded server. Phone-as-source /
	 * single-device deployments should leave this default — a
	 * 0.0.0.0 bind on a developer laptop without pairing protection
	 * exposes the OpenAI surface.
	 */
	httpBindHost?: string;

	/**
	 * Phase 4 — first-chance interceptor for /v1/chat/completions. The
	 * v3.1 Hub uses this to apply substitution-policy + engine-bridge
	 * routing before falling through to the default local-backend
	 * handler. Return a Response → that's what the client gets;
	 * return null → fall through to the local backend.
	 *
	 * Receives request headers (lower-cased keys) so the interceptor
	 * can read the v3.1 identity fields (X-DVAI-Peer-Device-Id,
	 * X-DVAI-App-Id, X-DVAI-Nonce, X-DVAI-Signature) for HMAC verify.
	 */
	chatCompletionInterceptor?: (
		body: any,
		ctx: import("./handlers/context.js").HandlerContext,
		headers?: Record<string, string>,
	) => Promise<Response | null>;

	/**
	 * HTTP-only. Controls the Access-Control-Allow-Origin response header.
	 * - "*"               → echo "*" (default; dev-friendly)
	 * - "https://x.com"   → echo that exact origin
	 * - ["a.com","b.com"] → match the request's Origin header against the
	 *                        list; echo the matched value. Requests from
	 *                        unlisted origins get ACAO omitted.
	 */
	corsOrigin?: string | string[];

	/**
	 * Capacitor-backend selection (when transport resolves to "capacitor").
	 * Default: "llama".
	 */
	capacitorBackend?: "llama" | "foundation" | "mediapipe";

	/**
	 * Path to the mmproj (vision projector) file when using a multimodal
	 * llama.cpp model. Optional; only required for vision-capable models.
	 */
	nativeMmprojPath?: string;
}

/**
 * DVAI: Local AI Orchestration
 * Orchestrates WebLLM or Transformers.js for local inference and selects
 * an MSW, HTTP, or Capacitor transport (auto-detected from environment)
 * to expose the OpenAI-compatible endpoint. On Capacitor, the native
 * runtime runs in a first-party plugin behind the "capacitor" transport.
 * Read `dvai.baseUrl` after initialize() to get the URL to point any
 * OpenAI SDK at.
 */
export class DVAI {
	public modelId: string;
	public mockUrl: string;
	public serviceWorkerUrl: string;
	public licenseKeyPath?: string;
	public licenseToken?: string;
	/**
	 * Result of the most recent license validation. Populated by
	 * `initialize()`; consult before promoting paid-tier UI affordances
	 * (e.g. hiding the attribution badge). Null before initialization.
	 */
	public licenseStatus: LicenseStatus | null = null;
	public backend: BackendType;
	public transformersModelId: string;
	public pipelineTask: string;
	public device: DeviceType;
	public generationTimeout: number;
	public maxBlankChunks: number;
	public maxRetries: number;
	public webllmWorkerUrl: string;
	public transformersWorkerUrl: string;
	public dtype?: string;
	public createPipeline?: import("./TransformersBackend.js").CreatePipelineFn;
	public transformersModelClass?: string;
	public transformersProcessorClass?: string;
	public transformersDisableEncoders?: string[];

	// Native backend options
	public nativeModelPath: string;
	public nativeGpuLayers: number;
	public nativeThreads: number;
	public nativeContextSize: number;
	public nativeEmbeddingMode: boolean;
	public capacitorBackend: "llama" | "foundation" | "mediapipe";
	public nativeMmprojPath?: string;

	/** Raw transport config (e.g., "auto"). */
	public transport: "auto" | "msw" | "http" | "none" | "capacitor";
	public httpBasePort: number;
	public httpMaxPortAttempts: number;
	public corsOrigin: string | string[];
	public httpBindHost: string | undefined;
	public chatCompletionInterceptor:
		| ((
				body: any,
				ctx: import("./handlers/context.js").HandlerContext,
				headers?: Record<string, string>,
			) => Promise<Response | null>)
		| undefined;

	/** Resolved transport kind after selectTransport() runs. */
	private resolvedTransport: "msw" | "http" | "none" | "capacitor" = "none";

	/** Populated after transport.start(). Undefined on "none". */
	public baseUrl?: string;
	public port?: number;

	/** Active transport instance; null before initialize() / after unload(). */
	private activeTransport: import("./transports/index.js").Transport | null =
		null;

	private validator: LicenseValidator;
	private backendInstance: any = null; // WebLLMBackend | TransformersBackend
	public isReady: boolean = false;
	/** Tracks how many consecutive recovery attempts have been made. */
	private recoveryAttempts: number = 0;

	/** The resolved backend type (after "auto" resolution). */
	private resolvedBackend: "webllm" | "transformers" | "native" = "webllm";

	/* ----- Phase 3 (v3.0+) — distributed-inference state ----- */

	/** OffloadConfig as supplied by the consumer (or undefined). */
	public offload?: import("./offload/index.js").OffloadConfig;
	/**
	 * v3.2 — set true when the pre-init capability gate decides this
	 * device is below `OffloadConfig.minLocalCapability`. In this mode
	 * `initialize()` skips backend init entirely (no model download /
	 * load) and only brings up discovery + pairing. Every request is
	 * expected to be forwarded to a paired peer; without one, requests
	 * 503.
	 */
	public offloadOnlyMode: boolean = false;
	/** Capability cache (persistent storage of probe scores). */
	private capabilityCache?: import("./capability/index.js").CapabilityCache;
	/** Phase 3 — built when offload.enabled; mounted on the HTTP transport via the handler context. */
	private dvaiRoutes?: Record<string, import("./handlers/dvai/index.js").DvaiHandler>;
	/** Used by the dvai/health endpoint to report uptime. */
	private startedAt: number = Date.now();
	/** Discovery layer — composite of LAN mDNS + static + custom. */
	private discovery?: import("./discovery/index.js").IDiscovery;
	/** Pairing policy (LAN-handshake auth + persistent store). */
	private pairingPolicy?: import("./pairing/index.js").PairingPolicy;
	/** Stable per-install device ID (cached after first call). */
	private deviceId?: string;

	constructor(config: DVAIConfig = {}) {
		this.modelId = config.modelId || "gemma-2-2b-it-q4f16_1-MLC";
		this.backend = config.backend || "webllm";
		this.transformersModelId =
			config.transformersModelId ||
			config.modelId ||
			"onnx-community/gemma-3n-E2B-it-ONNX";
		this.pipelineTask = config.pipelineTask || "text-generation";
		this.device = config.device || "auto";
		this.dtype = config.dtype;
		this.createPipeline = config.createPipeline;
		this.transformersModelClass = config.transformersModelClass;
		this.transformersProcessorClass = config.transformersProcessorClass;
		this.transformersDisableEncoders = config.transformersDisableEncoders;
		this.generationTimeout = config.generationTimeout ?? 60000;
		this.maxBlankChunks = config.maxBlankChunks ?? 20;
		this.maxRetries = config.maxRetries ?? 2;
		this.webllmWorkerUrl = config.webllmWorkerUrl ?? "/dvai-webllm.worker.js";
		this.transformersWorkerUrl =
			config.transformersWorkerUrl ?? "/dvai-transformers.worker.js";
		this.mockUrl =
			config.mockUrl ?? "https://api.openai.local/v1/chat/completions";
		this.serviceWorkerUrl = config.serviceWorkerUrl ?? "/mockServiceWorker.js";
		this.licenseKeyPath = config.licenseKeyPath;
		this.licenseToken = config.licenseToken;
		this.validator = new LicenseValidator({
			...(this.licenseKeyPath !== undefined ? { path: this.licenseKeyPath } : {}),
			...(this.licenseToken !== undefined ? { token: this.licenseToken } : {}),
		});

		// Native backend options
		this.nativeModelPath = config.nativeModelPath || "";
		this.nativeGpuLayers = config.nativeGpuLayers ?? 99;
		this.nativeThreads = config.nativeThreads ?? 4;
		this.nativeContextSize = config.nativeContextSize ?? 2048;
		this.nativeEmbeddingMode = config.nativeEmbeddingMode ?? false;
		this.capacitorBackend = config.capacitorBackend ?? "llama";
		this.nativeMmprojPath = config.nativeMmprojPath;

		// Transport options
		this.transport = config.transport ?? "auto";
		this.httpBasePort = config.httpBasePort ?? 38883;
		this.httpMaxPortAttempts = config.httpMaxPortAttempts ?? 16;
		this.corsOrigin = config.corsOrigin ?? "*";
		this.httpBindHost = config.httpBindHost;
		this.chatCompletionInterceptor = config.chatCompletionInterceptor;

		// Resolve explicit backends immediately so getActiveBackend() is correct
		// before initialize(). "auto" defers to initialize() for runtime env detection.
		if (this.backend !== "auto") {
			this.resolvedBackend = this.backend as "webllm" | "transformers" | "native";
		}

		// Phase 3 — capture offload config (lifecycle wiring lights up
		// in initialize() so we don't pay the cost on cold-construct).
		this.offload = config.offload;
	}

	/**
	 * Returns the active backend type (resolved from "auto" if applicable).
	 */
	getActiveBackend(): "webllm" | "transformers" | "native" {
		return this.resolvedBackend;
	}

	/** Returns the resolved transport kind (after "auto" resolution). */
	getActiveTransport(): "msw" | "http" | "none" | "capacitor" {
		return this.resolvedTransport;
	}

	/** Returns the base URL a host app hands to an OpenAI SDK. */
	getBaseUrl(): string | undefined {
		return this.baseUrl;
	}

	/** Returns the HTTP port bound (http transport only). */
	getPort(): number | undefined {
		return this.port;
	}

	/**
	 * Resolves the "auto" backend to a concrete type based on environment.
	 *
	 * On Capacitor, the native runtime is selected via `transport: "capacitor"`
	 * (which delegates to a native HTTP server in the Capacitor plugin), not
	 * via the backend. The backend stays in the webview as a thin client.
	 */
	private resolveBackend(): "webllm" | "transformers" | "native" {
		if (this.backend === "auto") {
			console.log(
				"[DVAI] Auto-detected web environment → using webllm backend",
			);
			return "webllm";
		}
		return this.backend as "webllm" | "transformers" | "native";
	}

	/**
	 * Initializes the selected backend engine and starts the resolved
	 * transport (MSW in browsers, HTTP server in Node, or none).
	 * @param onProgress - Callback for model download progress
	 */
	async initialize(
		onProgress: (info: any) => void = console.log,
	): Promise<boolean> {
		if (this.isReady) return true;

		// Resolve "auto" backend
		this.resolvedBackend = this.resolveBackend();

		// 0. Validate license (offline JWT verification). THROWS
		//    `LicenseRequiredError` in production / release contexts
		//    when no valid commercial/trial license is found — that's
		//    the BSL 1.1 enforcement point. Dev-mode environments
		//    (localhost, NODE_ENV=test, DVAI_FORCE_DEV=1, etc.) bypass
		//    the assert and return a `free-dev` status so developers
		//    can iterate without a key. Surface the resolved status
		//    through `this.licenseStatus` for host-app dashboards.
		this.licenseStatus = await this.validator.validateAndAssert();

		// Detect Web Worker context — MSW (service workers) are unavailable inside Web Workers.
		const isWorkerContext =
			typeof window === "undefined" &&
			typeof self !== "undefined" &&
			typeof (self as any).importScripts === "function";

		// 0.1 Verify Service Worker Reachability (Quality of Life) — skip when
		// inside a Worker context, and skip when serviceWorkerUrl is empty (MSW disabled).
		if (!isWorkerContext && this.serviceWorkerUrl) {
			try {
				const swRes = await fetch(this.serviceWorkerUrl, { method: "HEAD" });
				if (!swRes.ok) {
					console.warn(
						`[DVAI] Warning: Service Worker not found at "${this.serviceWorkerUrl}". ` +
							`Please run "dvai-bridge init" or "npx msw init <public_dir>" to generate it.`,
					);
				}
			} catch (e) {
				console.warn(
					`[DVAI] Could not verify Service Worker existence at "${this.serviceWorkerUrl}".`,
				);
			}
		}

		try {
			// 0.5 v3.2 — pre-init capability gate. Runs the heuristic
			// (CPU/GPU/RAM hints, no model required) and decides
			// internally whether to load a model locally:
			//
			//   - too-weak     → enter offload-only mode silently
			//                    (no model download/load). The SDK
			//                    does NOT throw and does NOT show any
			//                    UI — consumers query
			//                    `dvai.assessHardware()` ahead of
			//                    initialize() if they want to refuse
			//                    to start on too-weak devices.
			//   - offload-only → same internal treatment: skip backend
			//                    init; bring up only transport + offload.
			//   - ok           → proceed to full initialization.
			//
			// Both too-weak and offload-only collapse to "skip backend
			// init" from the SDK's perspective; the *informational*
			// distinction lives in assessHardware()'s return value for
			// consumers to react to.
			//
			// Skipped entirely when offload is not configured or when
			// `offload.enabled` is false — there's no point gating a
			// device that has no offload path.
			if (this.offload?.enabled) {
				const { assessCapability } =
					await import("./capability/precheck.js");
				const result = await assessCapability({
					hardwareMinimum: this.offload.hardwareMinimum,
					minLocalCapability: this.offload.minLocalCapability,
				});
				this.offloadOnlyMode =
					result.mode === "offload-only" || result.mode === "too-weak";
				onProgress({
					phase: "precheck",
					mode: result.mode,
					tokPerSec: result.tokPerSec,
					reason: result.reason,
				});
			}

			// 1. Initialize the selected backend (lazy import). Skipped
			// when the precheck put us in offload-only mode (or
			// too-weak) — the consumer won't be running inference
			// locally, so we don't pay the model download/load cost.
			if (!this.offloadOnlyMode) {
				await this.initializeBackend(onProgress);
			} else {
				onProgress({
					phase: "backend",
					skipped: true,
					reason: "offload-only mode (device below minLocalCapability or below hardwareMinimum)",
				});
			}

			// 2. Select transport based on env + config
			const { selectTransport, MswTransport, HttpTransport, CapacitorTransport } =
				await import("./transports/index.js");
			this.resolvedTransport = selectTransport({
				transport: this.transport === "auto" ? undefined : this.transport,
				serviceWorkerUrl: this.serviceWorkerUrl,
			});

			// Warn if mockUrl was explicitly customized under HTTP (will be ignored).
			// The default value is used as the sentinel for "user did not customize".
			if (
				this.resolvedTransport === "http" &&
				this.mockUrl !== "https://api.openai.local/v1/chat/completions"
			) {
				console.warn(
					"[DVAI] mockUrl config is ignored under transport=\"http\". " +
						"The HTTP server always serves at /v1/*. Use dvai.baseUrl " +
						"to get the exact endpoint.",
				);
			}

			// Warn if serviceWorkerUrl is empty but transport="msw" was forced
			if (
				this.resolvedTransport === "msw" &&
				this.serviceWorkerUrl === "" &&
				this.transport === "msw"
			) {
				console.warn(
					"[DVAI] serviceWorkerUrl is empty but transport='msw' was requested; MSW will fail to register.",
				);
			}

			// Worker-context informational message
			if (
				this.resolvedTransport === "none" &&
				typeof window === "undefined" &&
				typeof self !== "undefined"
			) {
				console.log(
					"[DVAI] Running in a Web Worker — no transport started. " +
						"Use dvai.chatCompletion() directly, or register MSW on the main thread.",
				);
			}

			// Construct + start the transport
			if (this.resolvedTransport === "msw") {
				this.activeTransport = new MswTransport({
					mockUrl: this.mockUrl,
					serviceWorkerUrl: this.serviceWorkerUrl,
				});
			} else if (this.resolvedTransport === "http") {
				this.activeTransport = new HttpTransport({
					httpBasePort: this.httpBasePort,
					httpMaxPortAttempts: this.httpMaxPortAttempts,
					corsOrigin: this.corsOrigin,
					...(this.httpBindHost !== undefined ? { bindHost: this.httpBindHost } : {}),
				});
			} else if (this.resolvedTransport === "capacitor") {
				this.activeTransport = new CapacitorTransport({
					capacitorBackend: this.capacitorBackend,
					nativeModelPath: this.nativeModelPath || undefined,
					nativeMmprojPath: this.nativeMmprojPath,
					nativeGpuLayers: this.nativeGpuLayers,
					nativeContextSize: this.nativeContextSize,
					nativeThreads: this.nativeThreads,
					nativeEmbeddingMode: this.nativeEmbeddingMode,
					httpBasePort: this.httpBasePort,
					httpMaxPortAttempts: this.httpMaxPortAttempts,
					corsOrigin: this.corsOrigin,
				});
			} else {
				this.activeTransport = null;
			}

			if (this.activeTransport) {
				const ctx = this.getHandlerContext(onProgress);
				const started = await this.activeTransport.start(ctx);
				this.baseUrl = started.baseUrl;
				this.port = started.port;
			} else {
				this.baseUrl = undefined;
				this.port = undefined;
			}

			this.isReady = true;
			this.recoveryAttempts = 0;

			// Phase 3 — bring up offload-related state if the consumer
			// opted in. Errors here are logged but do not fail
			// initialize() — local inference still works without offload.
			if (this.offload?.enabled) {
				try {
					await this.initializeOffload();
					// v3.2 — auto-attach the offload forwarder so requests
					// route to peers without the consumer wiring an
					// interceptor manually. Skipped when:
					//   1. The consumer already supplied their own
					//      chatCompletionInterceptor (e.g. the Hub uses
					//      one for substitution-policy routing — they're
					//      responsible for composing offload themselves).
					//   2. We're not in offload-only mode AND a local
					//      backend is available — for v3.2.0 we keep the
					//      auto-attach scoped to the offload-only path
					//      to avoid changing local-first behavior. The
					//      richer "decide per request even when local
					//      works" wiring follows in a future patch.
					if (
						this.chatCompletionInterceptor === undefined &&
						this.offloadOnlyMode
					) {
						const { buildOffloadInterceptor } = await import(
							"./offload/index.js"
						);
						const offloadConfig = this.offload;
						this.chatCompletionInterceptor = buildOffloadInterceptor({
							config: offloadConfig,
							getPeers: () => this.discovery?.peers() ?? [],
							getLocalCapability: () => 0, // offload-only ⇒ no local backend
							offloadOnlyMode: true,
						});
					}
				} catch (err) {
					console.warn(
						"[DVAI/offload] failed to initialize offload state; " +
							"local inference still works. Cause:",
						err,
					);
				}
			}

			return true;
		} catch (error) {
			console.error("[DVAI] Failed to initialize:", error);
			throw error;
		}
	}

	/**
	 * Phase 3 — bring up the capability cache, discovery layer, and
	 * pairing policy on top of an already-running DVAI instance.
	 * Called from initialize() when `offload.enabled` is true.
	 */
	private async initializeOffload(): Promise<void> {
		const { createCapabilityCache, ensureDeviceId } = await import(
			"./capability/index.js"
		);
		const { CompositeDiscovery, StaticDiscovery, createMdnsDiscovery } = await import(
			"./discovery/index.js"
		);
		const { PairingPolicy, createPairingStore } = await import(
			"./pairing/index.js"
		);

		this.capabilityCache = createCapabilityCache();
		this.deviceId = await ensureDeviceId(this.capabilityCache);

		const sources: Array<import("./discovery/index.js").IDiscovery> = [];
		if (this.offload?.discoverLAN !== false) {
			// v3.2.1 — when `offload.advertiseLAN` is true, register an
			// `_dvai-bridge._tcp` mDNS advertisement so remote peers
			// (mobile SDKs, other Hubs) can discover this instance via
			// NWBrowser without manual URL entry. The native SDKs
			// already do this themselves; the JS-side core (Hub, Node
			// CLI) opts in here. Port defaults to the bound DVAI server
			// port; `models` is empty until the Hub feeds enumeration
			// in (loadedModels via setLoadedModels at runtime).
			//
			// On macOS, the Hub's wrapper (`hub/peer-mode/server.ts`)
			// uses a `dns-sd -R` subprocess that goes through the
			// system mDNSResponder daemon — that's the canonical path
			// and Bonjour clients see a properly-named service
			// (`<DVAI Hub>` vs the generic `<hostname>.local`
			// `multicast-dns` produces). To avoid emitting duplicate
			// `_dvai-bridge._tcp` records, the JS-core's advertise
			// silently no-ops on Darwin — leave the macOS path to the
			// dns-sd subprocess. On Linux / Windows the npm lib's
			// advertise actually works (no system-daemon conflict),
			// so we keep it there.
			const skipAdvertiseOnDarwin =
				typeof globalThis.process !== "undefined" &&
				globalThis.process.platform === "darwin";
			const advertise: import("./discovery/mdns-node.js").AdvertisedTxt | undefined =
				this.offload?.advertiseLAN && !skipAdvertiseOnDarwin
					? {
							deviceId: this.deviceId,
							deviceName:
								(typeof globalThis.process !== "undefined" &&
									(globalThis.process.env.DVAI_DEVICE_NAME ?? "")) ||
								"DVAI",
							dvaiVersion: "3.2.1",
							// Default to the bound DVAI server port (set in
							// `start()` after the transport binds). If the
							// transport is `none` (rare for advertising), fall
							// back to the legacy default 38883.
							port:
								this.offload.advertisePort ??
								this.port ??
								38883,
							secure: false,
							// Field name matches the AdvertisedTxt schema
							// (NOT `loadedModels` — that's the iOS-side
							// struct name, not the wire encoding).
							models: [],
							capability: {},
						}
					: undefined;
			sources.push(
				await createMdnsDiscovery({
					selfDeviceId: this.deviceId,
					...(advertise ? { advertise } : {}),
				}),
			);
		}
		if (this.offload?.knownPeers && this.offload.knownPeers.length > 0) {
			sources.push(new StaticDiscovery(this.offload.knownPeers));
		}
		if (sources.length > 0) {
			this.discovery = new CompositeDiscovery(sources);
			await this.discovery.start();
		}

		this.pairingPolicy = new PairingPolicy({
			store: createPairingStore(),
			onPairingRequest: this.offload?.onPairingRequest
				? async (peerDeviceId, peerDeviceName, appId) => {
						const cb = this.offload?.onPairingRequest;
						if (!cb) return false;
						return cb({
							deviceId: peerDeviceId,
							deviceName: peerDeviceName,
							dvaiVersion: "unknown",
							baseUrl: "",
							loadedModels: [],
							capability: {},
							via: "static",
							secure: false,
							lastSeenAt: Date.now(),
							...(appId !== undefined ? { appId } : {}),
						});
					}
				: undefined,
		});

		// Build the /v1/dvai/* route map. The HTTP transport reads this
		// late via the handler-context getter (initializeOffload runs
		// AFTER the transport has started in the current lifecycle).
		const { buildDvaiRoutes } = await import("./handlers/dvai/index.js");
		const self = this;
		this.dvaiRoutes = buildDvaiRoutes({
			libraryVersion: "3.0.0",
			get currentModelId() {
				return self.resolvedBackend === "transformers"
					? self.transformersModelId
					: self.modelId;
			},
			capabilityCache: this.capabilityCache,
			get backend() {
				const b = self.backendInstance;
				if (!b) return undefined;
				// ProbableBackend just needs `chatCompletion` — duck-typed.
				return b as unknown as import("./capability/index.js").ProbableBackend;
			},
			discovery: this.discovery,
			pairingPolicy: this.pairingPolicy,
			startedAt: this.startedAt,
		} as Parameters<typeof buildDvaiRoutes>[0]);
	}

	/** Phase 3 — release offload state (LAN advertiser, discovery sockets, etc). */
	private async shutdownOffload(): Promise<void> {
		if (this.discovery) {
			try {
				await this.discovery.stop();
			} catch {
				/* swallow — best-effort cleanup */
			}
			this.discovery = undefined;
		}
		this.capabilityCache = undefined;
		this.pairingPolicy = undefined;
		this.dvaiRoutes = undefined;
		this.deviceId = undefined;
	}

	/**
	 * Builds a HandlerContext consumed by the transport-agnostic handlers.
	 * `backend` is exposed via a getter so that when recovery replaces
	 * `this.backendInstance` mid-request, the handler's subsequent reads of
	 * `ctx.backend` see the new instance (critical for the reactive-recovery
	 * retry path in handleChatCompletion).
	 */
	private getHandlerContext(
		onProgress: (info: any) => void,
	): HandlerContext {
		const self = this;
		return {
			get backend() {
				return self.backendInstance;
			},
			resolvedBackend: this.resolvedBackend,
			modelId:
				this.resolvedBackend === "transformers"
					? this.transformersModelId
					: this.modelId,
			onRecovery:
				this.resolvedBackend === "webllm"
					? async () => {
							if (
								this.backendInstance?.lastFatalError &&
								this.recoveryAttempts < this.maxRetries
							) {
								await this.attemptRecovery(onProgress);
							} else if (this.recoveryAttempts >= this.maxRetries) {
								throw new Error("Recovery exhausted");
							}
						}
					: undefined,
			// Phase 3 — late-bound getter so the HTTP transport sees
			// the routes once initializeOffload() finishes (which runs
			// AFTER the transport starts in the current lifecycle).
			get dvaiRoutes() {
				return self.dvaiRoutes;
			},
			// Phase 4 — Hub injects this to enforce substitution policy
			// + engine-bridge routing.
			...(this.chatCompletionInterceptor !== undefined
				? { chatCompletionInterceptor: this.chatCompletionInterceptor }
				: {}),
		};
	}

	/**
	 * Attempts to recover from a fatal WebLLM error by unloading and reloading the backend.
	 */
	private async attemptRecovery(
		onProgress: (info: any) => void,
	): Promise<void> {
		this.recoveryAttempts++;
		const fatalError = this.backendInstance?.lastFatalError;
		console.log(
			`[DVAI] Auto-recovery: unloading engine due to "${fatalError}" (attempt ${this.recoveryAttempts}/${this.maxRetries})`,
		);

		// Unload the backend
		if (this.backendInstance) {
			try {
				await this.backendInstance.unload();
			} catch (e) {
				console.warn("[DVAI] Error during recovery unload:", e);
			}
			this.backendInstance = null;
		}

		// Reload
		await this.initializeBackend(onProgress);
		if (this.backendInstance?.clearFatalError) {
			this.backendInstance.clearFatalError();
		}
		console.log("[DVAI] Auto-recovery: engine reloaded successfully");
	}

	/**
	 * Lazy-imports and initializes the selected backend.
	 */
	private async initializeBackend(
		onProgress: (info: any) => void,
	): Promise<void> {
		if (this.resolvedBackend === "native") {
			let NodeLlamaCppBackend: any;
			try {
				const mod = await import("./NodeLlamaCppBackend.js");
				NodeLlamaCppBackend = mod.NodeLlamaCppBackend;
			} catch {
				throw new Error(
					'[DVAI] native backend selected but the NodeLlamaCppBackend module failed to load.',
				);
			}
			if (!this.nativeModelPath) {
				throw new Error(
					'[DVAI] backend: "native" requires `nativeModelPath` (path to a GGUF file).',
				);
			}
			// Use modelId only if the consumer customized it; otherwise let
			// the backend derive it from the GGUF basename. The default
			// WebLLM model id is meaningless for the native backend.
			const customModelId =
				this.modelId !== "gemma-2-2b-it-q4f16_1-MLC" ? this.modelId : undefined;
			const backend = new NodeLlamaCppBackend({
				modelPath: this.nativeModelPath,
				gpuLayers: this.nativeGpuLayers,
				threads: this.nativeThreads,
				contextSize: this.nativeContextSize,
				generationTimeout: this.generationTimeout,
				modelId: customModelId,
			});
			await backend.initialize(onProgress);
			this.backendInstance = backend;
			// Echo the resolved model identifier (basename if not provided)
			this.modelId = backend.getModelId();
			console.log(
				`[DVAI] node-llama-cpp backend ready (modelId="${this.modelId}", gpuLayers=${this.nativeGpuLayers}, contextSize=${this.nativeContextSize})`,
			);
			return;
		}
		if (this.resolvedBackend === "transformers") {
			let TransformersBackend: any;
			try {
				const mod = await import("./TransformersBackend.js");
				TransformersBackend = mod.TransformersBackend;
			} catch {
				throw new Error(
					'[DVAI] Transformers.js backend selected but "@huggingface/transformers" is not installed.\n' +
						"Install it with: npm install @huggingface/transformers",
				);
			}
			const backend = new TransformersBackend({
				modelId: this.transformersModelId,
				device: this.device,
				generationTimeout: this.generationTimeout,
				workerUrl: this.transformersWorkerUrl,
				pipelineTask: this.pipelineTask,
				dtype: this.dtype,
				createPipeline: this.createPipeline,
				modelClass: this.transformersModelClass,
				processorClass: this.transformersProcessorClass,
				disableEncoders: this.transformersDisableEncoders,
			});
			await backend.initialize(onProgress);
			this.backendInstance = backend;
			console.log(
				`[DVAI] Transformers.js backend ready (task: ${this.pipelineTask}, device: ${backend.getResolvedDevice()}, worker: ${backend.isWorkerBased()})`,
			);
		} else {
			let WebLLMBackend: any;
			try {
				const mod = await import("./WebLLMBackend.js");
				WebLLMBackend = mod.WebLLMBackend;
			} catch {
				throw new Error(
					'[DVAI] WebLLM backend selected but "@mlc-ai/web-llm" is not installed.\n' +
						"Install it with: npm install @mlc-ai/web-llm",
				);
			}
			const backend = new WebLLMBackend({
				modelId: this.modelId,
				generationTimeout: this.generationTimeout,
				maxBlankChunks: this.maxBlankChunks,
				workerUrl: this.webllmWorkerUrl,
			});
			await backend.initialize(onProgress);
			this.backendInstance = backend;
			console.log(
				`[DVAI] WebLLM backend ready (worker: ${backend.isWorkerBased()})`,
			);
		}
	}

	/**
	 * Gets the underlying engine instance directly.
	 * - For WebLLM: returns the MLCEngine
	 * - For Transformers.js: returns the pipeline
	 */
	getEngine(): any {
		if (!this.backendInstance) return null;
		if (this.resolvedBackend === "webllm") {
			return this.backendInstance.getEngine?.() ?? null;
		}
		if (this.resolvedBackend === "native") {
			// node-llama-cpp doesn't expose a single "engine" — return the
			// chat session, which is the closest analogue.
			return this.backendInstance ?? null;
		}
		return this.backendInstance.getPipeline?.() ?? null;
	}

	/**
	 * Perform a direct chat completion (bypasses MSW, calls backend directly).
	 * Useful for programmatic usage without going through the fetch mock.
	 */
	async chatCompletion(requestBody: any): Promise<any> {
		if (!this.backendInstance)
			throw new Error(
				"[DVAI] Backend not initialized. Call initialize() first.",
			);
		return this.backendInstance.chatCompletion(requestBody);
	}

	/**
	 * Generate embeddings for one or more text inputs.
	 *
	 * Supported when backend is "transformers" with
	 * pipelineTask: "feature-extraction".
	 *
	 * Throws when called on the WebLLM backend.
	 *
	 * @param inputs - A single string or array of strings to embed
	 * @returns An array of embedding vectors (one per input)
	 */
	async embedding(inputs: string | string[]): Promise<number[][]> {
		if (!this.backendInstance)
			throw new Error(
				"[DVAI] Backend not initialized. Call initialize() first.",
			);
		if (this.resolvedBackend === "webllm") {
			throw new Error(
				"[DVAI] Embeddings are not supported on the WebLLM backend. " +
					"Use backend: 'transformers' with pipelineTask: 'feature-extraction'.",
			);
		}
		if (this.resolvedBackend === "native") {
			throw new Error(
				"[DVAI] Embeddings are not yet supported on the node-llama-cpp backend. " +
					"Use backend: 'transformers' with pipelineTask: 'feature-extraction'.",
			);
		}
		if (typeof this.backendInstance.embedding !== "function") {
			throw new Error(
				"[DVAI] The current backend does not expose an embedding() method.",
			);
		}
		return this.backendInstance.embedding(inputs);
	}

	/**
	 * Run the pipeline directly (Transformers.js only).
	 * Use this for non-text tasks like text-to-image, ASR, text-to-speech, etc.
	 * @param inputs - Input data appropriate for the pipeline task
	 * @param options - Pipeline-specific options
	 */
	async runPipeline(inputs: any, options?: Record<string, any>): Promise<any> {
		if (!this.backendInstance)
			throw new Error(
				"[DVAI] Backend not initialized. Call initialize() first.",
			);
		if (
			this.resolvedBackend !== "transformers" ||
			!this.backendInstance.runPipeline
		) {
			throw new Error(
				"[DVAI] runPipeline() is only available with the Transformers.js backend.",
			);
		}
		return this.backendInstance.runPipeline(inputs, options);
	}

	/**
	 * Unloads the AI engine and stops the active transport to free up resources.
	 */
	async unload(): Promise<void> {
		// Phase 3 — tear down offload state first so we stop advertising
		// before the underlying server disappears.
		await this.shutdownOffload();

		if (this.backendInstance) {
			await this.backendInstance.unload();
			this.backendInstance = null;
		}
		if (this.activeTransport) {
			await this.activeTransport.stop();
			this.activeTransport = null;
		}
		this.baseUrl = undefined;
		this.port = undefined;
		this.isReady = false;
		this.recoveryAttempts = 0;
		console.log("[DVAI] Unloaded model and transport.");
	}

	/* ----- Phase 3 — public surface for offload diagnostics ----- */

	/**
	 * v3.2 — pre-init hardware assessment.
	 *
	 * Returns a JSON-serializable description of how this device
	 * would handle local inference, BEFORE any model download/load.
	 *
	 * Consumers should call this before `initialize()` if they want
	 * to refuse to start on too-weak devices. The SDK itself never
	 * shows UI — it's the consumer app's job to decide what (if
	 * anything) to surface based on the result.
	 *
	 * Result `mode` values:
	 *   - `ok`           → device can comfortably run the model
	 *                      locally; initialize() will proceed normally.
	 *   - `offload-only` → device can run but slowly (below
	 *                      `minLocalCapability`); initialize() will
	 *                      skip the model load and route every
	 *                      request to a paired peer.
	 *   - `too-weak`     → device is below the hardware floor (3
	 *                      tok/s by default); initialize() will
	 *                      ALSO skip the model load — the consumer
	 *                      should typically bail rather than even
	 *                      calling initialize().
	 *
	 * Pass `hardwareMinimum` / `minLocalCapability` to override the
	 * defaults (matches `OffloadConfig`).
	 *
	 * @returns a serializable assessment (safe to JSON.stringify and
	 *   ship over a Pigeon / Capacitor channel).
	 */
	async assessHardware(opts: {
		hardwareMinimum?: number;
		minLocalCapability?: number;
	} = {}): Promise<{
		mode: "ok" | "offload-only" | "too-weak";
		tokPerSec: number;
		reason: string;
		hints: import("./capability/index.js").DeviceCapabilityHints;
	}> {
		const { assessCapability } = await import("./capability/precheck.js");
		const result = await assessCapability({
			hardwareMinimum: opts.hardwareMinimum,
			minLocalCapability: opts.minLocalCapability,
		});
		return {
			mode: result.mode,
			tokPerSec: result.tokPerSec,
			reason: result.reason,
			hints: result.hints,
		};
	}

	/**
	 * Run a cold-run capability probe against the active backend +
	 * model. Persists the result for future getCapability() calls.
	 * Requires offload.enabled.
	 */
	async probeCapability(): Promise<
		import("./capability/index.js").CapabilityScore | undefined
	> {
		if (!this.capabilityCache || !this.backendInstance) return undefined;
		const { probeAndCache } = await import("./capability/index.js");
		const modelId =
			this.resolvedBackend === "transformers"
				? this.transformersModelId
				: this.modelId;
		return probeAndCache({
			cache: this.capabilityCache,
			backend: this.backendInstance,
			modelId,
			libraryVersion: "3.0.0",
		});
	}

	/**
	 * Get the cached capability score for a model on this device, or
	 * compute a heuristic estimate if no probe has run yet.
	 */
	async getCapability(
		modelId?: string,
	): Promise<import("./capability/index.js").CapabilityScore | undefined> {
		if (!this.capabilityCache) return undefined;
		const { getCapability } = await import("./capability/index.js");
		const id =
			modelId ??
			(this.resolvedBackend === "transformers"
				? this.transformersModelId
				: this.modelId);
		return getCapability({
			cache: this.capabilityCache,
			modelId: id,
			libraryVersion: "3.0.0",
		});
	}

	/** Snapshot of currently-known peers via the discovery layer. */
	getPeers(): import("./discovery/index.js").Peer[] {
		return this.discovery?.peers() ?? [];
	}
}

// Export a singleton instance by default, or the class for advanced usage
export const dvai: DVAI = new DVAI();

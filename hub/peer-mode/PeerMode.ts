/**
 * Phase 4 — DVAI Hub PeerMode façade.
 *
 * The Hub runs a single long-lived `PeerMode` instance that does three
 * things on behalf of the host (Tauri shell, or a Flavor 2 fork):
 *
 *   1. Stands up the dvai-bridge embedded HTTP server in *target* mode
 *      so paired mobile apps can offload requests to it. (Wraps the
 *      existing v3.0 `DVAI` class with `offload.enabled = true`.)
 *
 *   2. Exposes per-tenant pairing isolation, so when two unrelated
 *      mobile apps both pair with this Hub, their pairings, capability
 *      caches, and audit logs stay separate. (Wraps `MultiTenantPairing`.)
 *
 *   3. Optionally surfaces external engines (Ollama, LM Studio, ...) so
 *      requests for models cached by *those* engines can be served
 *      without the user having to predownload them via the Hub UI.
 *      (Wraps `EngineBridge`.)
 *
 * The façade is intentionally narrow — it's the contract the Tauri
 * Rust shell calls into via Node-side IPC. UI components never touch
 * the underlying primitives directly; they go through PeerMode methods.
 *
 * NOTE: this file declares the public surface and the orchestration
 * shell. The actual wiring to `@dvai-bridge/core`'s `DVAI` class is
 * a thin pass-through; consumers can also pass a pre-constructed `DVAI`
 * for advanced configurations (custom backends, transports).
 */

import { EngineBridge, type EngineSummary } from "./EngineBridge.js";
import {
  MultiTenantPairing,
  MultiTenantPairingError,
  type OffloadAudit,
  type Pairing,
  type PairingRequest,
} from "./MultiTenantPairing.js";
import {
  parseModelName as parseModelNameForBackend,
  type ModelDescriptor,
} from "./ModelParser.js";
import {
  SubstitutionPolicy,
  type BackendDescriptor,
  type RoutingDecision,
} from "./SubstitutionPolicy.js";

/**
 * Structural type matching `@dvai-bridge/core`'s public `DVAI` class.
 * Defined locally to avoid coupling PeerMode to the core's deep import
 * paths. The shell injects either the real `DVAI` or a mock at start()
 * via `dvaiFactory` — keeping this façade unit-testable without a real
 * embedded HTTP server.
 */
export interface DvaiServerLike {
  baseUrl?: string;
  port?: number;
  initialize: (...args: unknown[]) => Promise<unknown>;
  unload: () => Promise<void>;
}

/**
 * Structural type matching `@dvai-bridge/core`'s `Peer` (a remote
 * device that wants to offload to this Hub). Only the fields the Hub
 * uses to compose a `PairingRequest` are listed here.
 */
export interface DvaiPeerLike {
  deviceId: string;
  deviceName: string;
  dvaiVersion: string;
  baseUrl: string;
  /**
   * v3.1 wire-protocol extension. When present, the Hub uses this as
   * the multi-tenant appId (real per-app isolation). When absent,
   * falls back to deviceId so the Hub still works with v3.0 SDKs.
   */
  appId?: string;
}

/* -------------------------------------------------------------------------- */
/* Options                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Description of one internal (in-process) backend the Hub can run.
 *
 * Before v3.2.x the Hub only supported a single internal backend
 * (selected via the `DVAI_HUB_BACKEND` env var at sidecar boot). The
 * UI synthesised one engine card to represent it, with no way for the
 * user to switch between options at runtime.
 *
 * From v3.2.x onward, the host (server.ts) declares *all* internal
 * backends it can run as a list of `InternalEngineConfig`. Each entry
 * surfaces as a real `EngineSummary` in `getDetectedEngines()` and can
 * be toggled like any external adapter. Toggling an internal engine on
 * triggers a full DVAI rebuild via `dvaiFactory(backend, ...)`.
 *
 * Mutual exclusivity is enforced: at most one internal engine *or* one
 * external adapter is "enabled" at any time — the Hub serves whichever
 * the user has currently selected.
 */
export interface InternalEngineConfig {
  /** Display name shown in the UI. Should include a `(Internal)` marker. */
  name: string;
  /** Backend identifier passed verbatim to `dvaiFactory(backend, ...)`. */
  backend: string;
  /**
   * Model identifier registered into `localBackends` when this engine
   * is enabled. Parsed by `parseModelName()` so the SubstitutionPolicy
   * can reason about it semantically. e.g. an HF hub id for
   * Transformers.js, or a GGUF basename for node-llama-cpp.
   */
  modelId: string;
  /**
   * True if this backend is compiled into the current Hub build.
   * Drives the UI's "Detected & Online" indicator and the disabled
   * state of the toggle. Internal-engine detection is build-time, not
   * runtime — it answers "can the user pick this?" not "is it loaded?".
   */
  detected: boolean;
}

export interface PeerModeOptions {
  /** Where per-tenant state lives on disk. Required. */
  storeDir: string;
  /** Optional rendezvous URL for the internet-discovery path. */
  rendezvousUrl?: string;
  /** Master switch for surfacing external engines (Ollama, LM Studio, etc.). */
  externalEnginesEnabled: boolean;
  /** Adapters the bridge should drive when externalEngines is enabled. */
  engineAdapters?: EngineBridgeAdapter[];
  /**
   * Internal backends the Hub may run, listed in preference order.
   * The first `detected: true` entry is auto-enabled on first start
   * (Option β behaviour). Default `[]` means no internal engine surfaces
   * and no DVAI server is constructed unless an external engine is
   * explicitly enabled.
   */
  internalEngines?: InternalEngineConfig[];
  /** TCP port to bind. The wrapper falls back to a free port if unavailable. */
  port?: number;
  /** Bind host. Default `0.0.0.0` for LAN reachability. */
  bindHost?: string;
  /** Flavor 2 lockdown: only these appIds may pair. Empty/undefined = allow any. */
  multiTenant?: { allowedAppIds?: string[] };
  /** UI hook fired when a fresh peer wants to pair. */
  onPairingRequest: (request: PairingRequest) => Promise<boolean>;
  /** Diagnostic callback after each served offload request (lands in audit log). */
  onOffloadServed?: (audit: OffloadAudit) => void;
  /** If true, allow lower-quality quants to be served (default false — strict). */
  preferBetterQuant?: boolean;
  /**
   * Factory that constructs the underlying `DVAI` server for a given
   * backend identifier. Called from `start()` (for the auto-enabled
   * engine) and again from `setEngineEnabled()` when the user switches
   * between internal engines at runtime — each switch rebuilds the
   * DVAI server with the new backend.
   *
   * The factory receives:
   *   - `backend` — the value of `InternalEngineConfig.backend`
   *   - `onPairingRequest` — wired to the multi-tenant store
   *
   * When `internalEngines` is empty *or* no factory is supplied, no
   * embedded HTTP server is constructed — useful for unit tests and
   * for deployments where DVAI is managed externally and surfaced via
   * `setServerInfo()`.
   */
  dvaiFactory?: (
    backend: string,
    onPairingRequest: (
      peer: DvaiPeerLike,
    ) => Promise<
      | boolean
      | { approved: true; pairingKey: string }
      | { approved: false }
    >,
  ) => Promise<DvaiServerLike> | DvaiServerLike;
}

/** EngineBridge adapter, re-exported for convenience. */
export type EngineBridgeAdapter = import("./EngineBridge.js").EngineAdapter;

/* -------------------------------------------------------------------------- */
/* Status surface                                                             */
/* -------------------------------------------------------------------------- */

export interface PeerModeStatus {
  running: boolean;
  port: number | null;
  baseUrl: string | null;
  startedAt: number | null;
}

/* -------------------------------------------------------------------------- */
/* Implementation                                                             */
/* -------------------------------------------------------------------------- */

export class PeerMode {
  private readonly opts: PeerModeOptions;
  private readonly tenants: MultiTenantPairing;
  private readonly engines: EngineBridge;
  private readonly substitution: SubstitutionPolicy;

  private status: PeerModeStatus = {
    running: false,
    port: null,
    baseUrl: null,
    startedAt: null,
  };

  /**
   * Backends contributed by the Hub's first-party local backends.
   * Wired up by the Tauri Rust shell (or a manual setter for tests)
   * after the embedded HTTP server is started — local model loading
   * is asynchronous and unrelated to the wrapper's lifecycle.
   */
  private localBackends: BackendDescriptor[] = [];
  /**
   * Catalog of internal backends this PeerMode can run. Populated from
   * `opts.internalEngines`. Empty by default — the Hub server passes a
   * concrete list at construction time (transformers, native, …).
   */
  private readonly internalEngines: InternalEngineConfig[];
  /**
   * Name of the currently-active internal engine, or null if none is
   * enabled. When non-null, `this.dvai` is the DVAI server constructed
   * via `dvaiFactory(cfg.backend, …)` for the matching config.
   */
  private activeInternalEngine: string | null = null;

  /**
   * Reference to the embedded DVAI server when `dvaiFactory` is set.
   * `start()` constructs it; `stop()` calls `unload()`. When the
   * factory is unset, this stays `null` and the wrapper runs without
   * an HTTP plane (test mode).
   */
  private dvai: DvaiServerLike | null = null;

  constructor(opts: PeerModeOptions) {
    this.opts = opts;
    this.internalEngines = opts.internalEngines ?? [];
    this.tenants = new MultiTenantPairing({
      storeDir: opts.storeDir,
      onPairingRequest: opts.onPairingRequest,
      ...(opts.multiTenant?.allowedAppIds !== undefined
        ? { allowedAppIds: opts.multiTenant.allowedAppIds }
        : {}),
    });
    this.engines = new EngineBridge({
      enabled: opts.externalEnginesEnabled,
      adapters: opts.engineAdapters ?? [],
    });
    this.substitution = new SubstitutionPolicy({
      preferBetterQuant: opts.preferBetterQuant ?? false,
    });
  }

  /**
   * Start every layer. Idempotent — calling start() while running is a no-op.
   *
   * Order:
   *   1. Engine bridge brings up + enumerates external engines (Ollama / LM Studio / etc.).
   *   2. Mark running. The DVAI server itself is NOT yet constructed —
   *      that happens in `setEngineEnabled()` once the host has decided
   *      which internal engine (or none) should be active. The host
   *      (`server.ts`) loads its persisted `enabledEngine` setting and
   *      calls `setEngineEnabled(name, true)` immediately after start;
   *      on first run, Option β auto-enables the first detected internal
   *      engine.
   *
   * Lazy DVAI construction lets the user switch backends at runtime
   * without restarting the whole sidecar — `setEngineEnabled()` tears
   * down the old DVAI and stands up a new one with the chosen backend.
   */
  async start(): Promise<PeerModeStatus> {
    if (this.status.running) return this.status;
    await this.engines.start();
    this.status = {
      running: true,
      port: this.opts.port ?? null,
      baseUrl: null,
      startedAt: Date.now(),
    };
    return this.status;
  }

  async stop(): Promise<void> {
    if (!this.status.running) return;
    await this.teardownDvai();
    this.activeInternalEngine = null;
    this.localBackends = [];
    await this.engines.stop();
    this.status = { running: false, port: null, baseUrl: null, startedAt: null };
  }

  /**
   * Bridge between DVAI's `Peer`-keyed pairing handshake and the
   * Hub's `appId`-keyed multi-tenant store.
   *
   * v3.1 wire protocol carries `appId` in the handshake. When the
   * peer supplies it → real per-app isolation. When the peer is a
   * v3.0 SDK that doesn't send appId → fall back to deviceId so the
   * Hub still works.
   *
   * Returns the host-style pairing object so DVAI's PairingPolicy
   * uses the SAME key Hub stored in MultiTenantPairing. Avoids the
   * "two parallel stores generating divergent keys" bug.
   */
  private async handleDvaiPairingRequest(
    peer: DvaiPeerLike,
  ): Promise<{ approved: true; pairingKey: string } | { approved: false }> {
    const request: PairingRequest = {
      peerDeviceId: peer.deviceId,
      peerDeviceName: peer.deviceName,
      appId: peer.appId ?? peer.deviceId,
      dvaiVersion: peer.dvaiVersion,
    };
    try {
      const pairing = await this.tenants.approveOrFetch(request);
      return { approved: true, pairingKey: pairing.pairingKey };
    } catch (err) {
      if (err instanceof MultiTenantPairingError) {
        // denied / app_not_allowed → cleanly say no to the peer.
        return { approved: false };
      }
      throw err;
    }
  }

  /**
   * Inform PeerMode about the embedded HTTP server's bind address.
   * Called by the Tauri shell once `dvai.initialize()` resolves and
   * `dvai.baseUrl` is known. Returns the merged status snapshot.
   */
  setServerInfo(info: { port: number; baseUrl: string }): PeerModeStatus {
    this.status = {
      ...this.status,
      port: info.port,
      baseUrl: info.baseUrl,
    };
    return { ...this.status };
  }

  /**
   * Update the list of locally-cached backends the Hub itself can serve.
   * Invoked by the Hub's model-management UI when a model finishes
   * downloading or is deleted. Treat this like a setter of a snapshot.
   */
  setLocalBackends(backends: BackendDescriptor[]): void {
    this.localBackends = [...backends];
  }

  /**
   * Find an internal engine config by case-insensitive name match. The
   * UI passes the display name verbatim from `getDetectedEngines()`,
   * but we tolerate casing differences for robustness against env-var-
   * driven name variations.
   */
  private findInternalEngine(name: string): InternalEngineConfig | undefined {
    return this.internalEngines.find(
      (e) => e.name.toLowerCase() === name.toLowerCase(),
    );
  }

  /**
   * Toggle an engine on or off. Enforces mutual exclusivity: enabling
   * any engine (internal or external) disables every other engine.
   *
   * Internal engine semantics (the swap path):
   *   - If enabling a different internal engine than the current one,
   *     unload the existing DVAI server (if any) and call
   *     `dvaiFactory(cfg.backend, …)` to build a new one with the
   *     selected backend. Update `activeInternalEngine` + `localBackends`
   *     to reflect the new selection.
   *   - If enabling the *same* internal engine that's already active,
   *     no-op.
   *   - If disabling the active internal engine, unload the DVAI server
   *     and clear `activeInternalEngine` + `localBackends`.
   *
   * External engine semantics (the EngineBridge path):
   *   - Enabling an external engine disables every other engine AND
   *     the active internal one (so the DVAI server is torn down).
   *   - Disabling an external engine is a simple flag-flip on the
   *     bridge's cache entry.
   *
   * This method is async because backend swapping requires awaiting
   * `dvai.unload()` and `dvai.initialize()`. Callers must await it.
   */
  async setEngineEnabled(name: string, enabled: boolean): Promise<void> {
    const internalCfg = this.findInternalEngine(name);
    const isInternal = internalCfg !== undefined;

    if (!enabled) {
      // Disabling path.
      if (isInternal) {
        if (this.activeInternalEngine === internalCfg!.name) {
          await this.teardownDvai();
          this.activeInternalEngine = null;
          this.localBackends = [];
        }
      } else {
        this.engines.setEnabled(name, false);
      }
      return;
    }

    // Enabling path. First disable everything that isn't the target.
    if (isInternal) {
      // Disable all external engines.
      for (const summary of this.engines.detected()) {
        this.engines.setEnabled(summary.name, false);
      }
      // Swap to the requested internal engine if not already active.
      if (this.activeInternalEngine !== internalCfg!.name) {
        await this.teardownDvai();
        await this.constructDvai(internalCfg!);
        this.activeInternalEngine = internalCfg!.name;
      }
    } else {
      // Enabling an external engine — tear down any active internal
      // DVAI and disable every other external engine.
      if (this.activeInternalEngine !== null) {
        await this.teardownDvai();
        this.activeInternalEngine = null;
        this.localBackends = [];
      }
      for (const summary of this.engines.detected()) {
        this.engines.setEnabled(
          summary.name,
          summary.name.toLowerCase() === name.toLowerCase(),
        );
      }
    }
  }

  /**
   * Construct a fresh DVAI server for the given internal-engine config,
   * initialize it, and register the engine's model into `localBackends`
   * so the substitution policy can route requests to it.
   *
   * No-op if `opts.dvaiFactory` is undefined — the wrapper is running
   * in test mode and the host manages DVAI lifecycle externally.
   */
  private async constructDvai(cfg: InternalEngineConfig): Promise<void> {
    if (!this.opts.dvaiFactory) return;
    this.dvai = await this.opts.dvaiFactory(cfg.backend, (peer) =>
      this.handleDvaiPairingRequest(peer),
    );
    await this.dvai.initialize();
    this.status = {
      ...this.status,
      port: this.dvai.port ?? this.opts.port ?? null,
      baseUrl: this.dvai.baseUrl ?? null,
    };
    // Register the engine's model so the substitution policy sees it.
    // The host (server.ts) may override this with a different list via
    // `setLocalBackends()` once a real model is loaded; this is the
    // initial declaration.
    this.localBackends = [
      {
        descriptor: parseModelNameForBackend(cfg.modelId),
        engine: "builtin",
        engineModelId: cfg.modelId,
      },
    ];
  }

  /**
   * Unload the active DVAI server (if any). Wraps `dvai.unload()` in a
   * try/catch because failure to unload must not block the rest of the
   * swap — we still want to construct the new backend.
   */
  private async teardownDvai(): Promise<void> {
    if (!this.dvai) return;
    try {
      await this.dvai.unload();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      // eslint-disable-next-line no-console
      console.warn(`[PeerMode] dvai.unload() during swap failed: ${msg}`);
    }
    this.dvai = null;
    this.status = {
      ...this.status,
      port: null,
      baseUrl: null,
    };
  }

  /**
   * Returns the routing decision for a given parsed request descriptor.
   * Combines locally-cached backends + (optionally) external engines.
   * Callers (the request handler) must:
   *   1. Inspect the decision kind.
   *   2. For `exact`/`substituted`, route the request through the
   *      backend's owning engine (or local backend).
   *   3. For `refuse`, return a structured error to the requesting peer.
   *   4. Always record an `OffloadAudit` entry afterwards.
   */
  async routeRequest(request: ModelDescriptor): Promise<RoutingDecision> {
    const externalBackends = await this.engines.enumerateAvailable();
    const all = [...this.localBackends, ...externalBackends];
    return this.substitution.pick(request, all);
  }

  /* ----------------------------------------------------------------------- */
  /* Tenant + audit surface                                                  */
  /* ----------------------------------------------------------------------- */

  /** Approve (or recall) a pairing for a peer + appId. */
  approveOrFetchPairing(request: PairingRequest): Promise<Pairing> {
    return this.tenants.approveOrFetch(request);
  }

  findActivePairing(appId: string, peerDeviceId: string): Promise<Pairing | undefined> {
    return this.tenants.findActivePairing(appId, peerDeviceId);
  }

  touchPairing(appId: string, peerDeviceId: string): Promise<void> {
    return this.tenants.touchPairing(appId, peerDeviceId);
  }

  revokePairing(appId: string, peerDeviceId: string): Promise<void> {
    return this.tenants.revoke(appId, peerDeviceId);
  }

  revokeAllForApp(appId: string): Promise<void> {
    return this.tenants.revokeAll(appId);
  }

  listAllPairings(): Promise<Pairing[]> {
    return this.tenants.listAll();
  }

  listPairingsForApp(appId: string): Promise<Pairing[]> {
    return this.tenants.listForApp(appId);
  }

  async recordOffloadAudit(entry: OffloadAudit): Promise<void> {
    await this.tenants.recordAudit(entry.appId, entry);
    if (this.opts.onOffloadServed) {
      try {
        this.opts.onOffloadServed(entry);
      } catch {
        // host-app callbacks must never crash the wrapper
      }
    }
  }

  getAppAudit(appId: string, limit?: number): Promise<OffloadAudit[]> {
    return this.tenants.getAppAudit(appId, limit);
  }

  /* ----------------------------------------------------------------------- */
  /* Status surface for the dashboard                                        */
  /* ----------------------------------------------------------------------- */

  getStatus(): PeerModeStatus {
    return { ...this.status };
  }

  /**
   * Snapshot of every engine (internal + external) for the dashboard.
   *
   * Internal engines come first, in `internalEngines` order, so the UI
   * can group them under "Internal Runtimes". External engines follow
   * in adapter order under "External Bridges".
   *
   * For internal engines:
   *   - `detected` reflects build-time availability (the config's
   *     `detected` flag). Not gated on `status.running` — the user can
   *     pre-select an engine before starting the Hub.
   *   - `enabled` is true iff this engine is `activeInternalEngine`.
   *   - `modelCount` is the size of `localBackends` only for the active
   *     engine (other internal entries report 0 to avoid implying they
   *     own those models).
   *   - `lastEnumeratedAt` is `status.startedAt` (no per-engine probe).
   */
  getDetectedEngines(): EngineSummary[] {
    const internal: EngineSummary[] = this.internalEngines.map((cfg) => ({
      name: cfg.name,
      detected: cfg.detected,
      enabled: this.activeInternalEngine === cfg.name,
      modelCount:
        this.activeInternalEngine === cfg.name ? this.localBackends.length : 0,
      lastEnumeratedAt: this.status.startedAt ?? 0,
    }));
    const external = this.engines.detected();
    return [...internal, ...external];
  }

  /** Snapshot of currently-cached locally-loaded models. */
  getCachedModels(): BackendDescriptor[] {
    return [...this.localBackends];
  }

  /** Force re-enumeration of one (or all) external engine adapter(s). */
  invalidateEngineCache(adapterName?: string): Promise<void> {
    return this.engines.invalidateCache(adapterName);
  }

  /** Forwarded look-up (used by the request-routing handler). */
  findEngineAdapter(engineName: string): EngineBridgeAdapter | undefined {
    return this.engines.findAdapter(engineName);
  }
}

/* -------------------------------------------------------------------------- */
/* Re-exports — single import surface for the Tauri shell + dev fork.          */
/* -------------------------------------------------------------------------- */

export type {
  EngineSummary,
  ChatRequest,
  ChatResponse,
  StreamResponse,
} from "./EngineBridge.js";
export type {
  Pairing,
  PairingRequest,
  OffloadAudit,
} from "./MultiTenantPairing.js";
export { MultiTenantPairingError } from "./MultiTenantPairing.js";
export type { ModelDescriptor } from "./ModelParser.js";
export type {
  BackendDescriptor,
  RoutingDecision,
  SubstitutionRefuseReason,
} from "./SubstitutionPolicy.js";

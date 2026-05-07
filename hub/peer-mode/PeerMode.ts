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
  type OffloadAudit,
  type Pairing,
  type PairingRequest,
} from "./MultiTenantPairing.js";
import { type ModelDescriptor } from "./ModelParser.js";
import {
  SubstitutionPolicy,
  type BackendDescriptor,
  type RoutingDecision,
} from "./SubstitutionPolicy.js";

/* -------------------------------------------------------------------------- */
/* Options                                                                    */
/* -------------------------------------------------------------------------- */

export interface PeerModeOptions {
  /** Where per-tenant state lives on disk. Required. */
  storeDir: string;
  /** Optional rendezvous URL for the internet-discovery path. */
  rendezvousUrl?: string;
  /** Master switch for surfacing external engines (Ollama, LM Studio, etc.). */
  externalEnginesEnabled: boolean;
  /** Adapters the bridge should drive when externalEngines is enabled. */
  engineAdapters?: EngineBridgeAdapter[];
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

  constructor(opts: PeerModeOptions) {
    this.opts = opts;
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
   * NOTE: in the v3.1 cut, the embedded HTTP server is started by the Tauri
   * Rust shell (which owns process lifecycle), and the resulting baseUrl is
   * fed into PeerMode via `setServerInfo()`. This keeps PeerMode pure-Node
   * and Tauri-IPC-friendly — callers that don't want Tauri (e.g. tests, or
   * a CLI variant) can call `setServerInfo()` themselves.
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
    await this.engines.stop();
    this.status = { running: false, port: null, baseUrl: null, startedAt: null };
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

  getDetectedEngines(): EngineSummary[] {
    return this.engines.detected();
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

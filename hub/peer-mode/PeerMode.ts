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
import { type ModelDescriptor } from "./ModelParser.js";
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
}

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
  /**
   * Factory that constructs the underlying `DVAI` server. When provided,
   * `start()` instantiates the server, calls `initialize()`, forces
   * `offload.enabled=true`, and surfaces its `baseUrl` through the
   * status object. The factory receives a `dvaiOnPairingRequest`
   * callback that the PeerMode wires to its `MultiTenantPairing`.
   *
   * When undefined, no embedded HTTP server is started — useful for
   * unit tests and for advanced deployments where DVAI is managed
   * externally and stitched in via `setServerInfo()`.
   *
   * The factory pattern (rather than a direct DVAI dependency) keeps
   * peer-mode unit-testable without pulling the entire core into the
   * test bundle.
   */
  dvaiFactory?: (
    onPairingRequest: (peer: DvaiPeerLike) => Promise<boolean>,
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
   * Reference to the embedded DVAI server when `dvaiFactory` is set.
   * `start()` constructs it; `stop()` calls `unload()`. When the
   * factory is unset, this stays `null` and the wrapper runs without
   * an HTTP plane (test mode).
   */
  private dvai: DvaiServerLike | null = null;

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
   * Order:
   *   1. Engine bridge brings up + enumerates external engines (Ollama / LM Studio / etc.).
   *   2. If a `dvaiFactory` was provided, construct the DVAI server,
   *      wire its `onPairingRequest` to the multi-tenant store, and
   *      call `initialize()`. Surface `baseUrl` + `port`.
   *   3. Mark running.
   *
   * If `dvaiFactory` is unset, no HTTP plane is started — the wrapper
   * runs only the engine-bridge + tenants + substitution-policy
   * surfaces. Useful for tests and for advanced deployments where the
   * caller manages the DVAI lifecycle externally and uses
   * `setServerInfo()` to feed in the baseUrl.
   */
  async start(): Promise<PeerModeStatus> {
    if (this.status.running) return this.status;
    await this.engines.start();

    if (this.opts.dvaiFactory) {
      this.dvai = await this.opts.dvaiFactory((peer) =>
        this.handleDvaiPairingRequest(peer),
      );
      await this.dvai.initialize();
      this.status = {
        running: true,
        port: this.dvai.port ?? this.opts.port ?? null,
        baseUrl: this.dvai.baseUrl ?? null,
        startedAt: Date.now(),
      };
    } else {
      this.status = {
        running: true,
        port: this.opts.port ?? null,
        baseUrl: null,
        startedAt: Date.now(),
      };
    }
    return this.status;
  }

  async stop(): Promise<void> {
    if (!this.status.running) return;
    if (this.dvai) {
      try {
        await this.dvai.unload();
      } catch (err) {
        // Server unload errors must not prevent the rest of stop() from running —
        // the wrapper still wants to release engine bridge + clear pairing memory.
        const msg = err instanceof Error ? err.message : String(err);
        // eslint-disable-next-line no-console
        console.warn(`[PeerMode] dvai.unload() failed: ${msg}`);
      }
      this.dvai = null;
    }
    await this.engines.stop();
    this.status = { running: false, port: null, baseUrl: null, startedAt: null };
  }

  /**
   * Bridge between v3.0 DVAI's `Peer`-keyed pairing handshake and the
   * Hub's `appId`-keyed multi-tenant store.
   *
   * v3.0 wire protocol does NOT carry `appId` — every peer that pairs
   * looks the same to the Hub. As a v3.1 finalization item, the
   * handshake will be extended with an `appId` field; until then we
   * use `peer.deviceId` as the appId so each device is its own tenant.
   * The audit log still groups correctly; it just doesn't differentiate
   * "two apps from the same phone."
   */
  private async handleDvaiPairingRequest(peer: DvaiPeerLike): Promise<boolean> {
    const request: PairingRequest = {
      peerDeviceId: peer.deviceId,
      peerDeviceName: peer.deviceName,
      // FIXME(v3.1-final): replace with peer.appId once HandshakeRequest carries it.
      appId: peer.deviceId,
      dvaiVersion: peer.dvaiVersion,
    };
    try {
      await this.tenants.approveOrFetch(request);
      return true;
    } catch (err) {
      if (err instanceof MultiTenantPairingError) {
        // denied / app_not_allowed → cleanly say no to the peer.
        return false;
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

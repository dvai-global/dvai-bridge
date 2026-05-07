/**
 * Node mDNS / DNS-SD discovery + advertisement.
 *
 * Backed by `multicast-dns` (optional dep — if not installed, this
 * module logs a warning and degrades to no-op). The decision to keep
 * the dep optional avoids forcing a transitive native dep on every
 * dvai-bridge-core consumer; the offload feature itself is opt-in.
 */

import type { DiscoveryEvent, IDiscovery, Peer } from "./types.js";
import { MDNS_SERVICE_TYPE } from "./types.js";

/**
 * Loose typing for the multicast-dns module — we don't take a hard
 * dep on its types (would force the install).
 */
interface MdnsInstance {
  on(event: "response", handler: (response: MdnsResponse) => void): void;
  query(query: { questions: Array<{ name: string; type: string }> }): void;
  respond(response: { answers: MdnsAnswer[] }): void;
  destroy(): void;
}
interface MdnsResponse {
  answers: MdnsAnswer[];
  additionals?: MdnsAnswer[];
}
interface MdnsAnswer {
  name: string;
  type: string;
  data: unknown;
  ttl?: number;
}

/** Fields we advertise in the TXT record per the spec §4.2. */
export interface AdvertisedTxt {
  dvaiVersion: string;
  deviceId: string;
  deviceName: string;
  models: string[];
  capability: Record<string, number>;
  port: number;
  secure: boolean;
}

export class NodeMdnsDiscovery implements IDiscovery {
  private mdns?: MdnsInstance;
  private readonly peerMap = new Map<string, Peer>();
  private readonly listeners = new Set<(e: DiscoveryEvent) => void>();
  private queryTimer?: NodeJS.Timeout;
  private gcTimer?: NodeJS.Timeout;
  private started = false;

  constructor(
    private readonly opts: {
      /** Our own deviceId — filter so we don't return ourselves. */
      selfDeviceId: string;
      /** Optional: TXT we should advertise. If omitted, we discover-only. */
      advertise?: AdvertisedTxt;
      /** How often to re-broadcast queries. Default 30s. */
      queryIntervalMs?: number;
      /** GC interval for stale peers (no recent advertisement). Default 60s. */
      gcIntervalMs?: number;
      /** TTL after which a peer is considered down (no recent ad). Default 90s. */
      peerTtlMs?: number;
    },
  ) {}

  async start(): Promise<void> {
    if (this.started) return;

    let mod: { default?: (opts?: unknown) => MdnsInstance } | ((opts?: unknown) => MdnsInstance);
    try {
      // @ts-expect-error — optional dep; consumers install only if they want LAN discovery.
      mod = await import("multicast-dns");
    } catch {
      this.emit({
        type: "error",
        message:
          "[DVAI/discovery] `multicast-dns` not installed; LAN discovery disabled. " +
          "Install with `npm i multicast-dns` (optional dep) to enable peer discovery.",
      });
      return;
    }
    const factory = (typeof mod === "function" ? mod : mod.default) as (
      opts?: unknown,
    ) => MdnsInstance;
    this.mdns = factory();
    this.started = true;

    this.mdns.on("response", (response) => this.onResponse(response));

    // Initial query + periodic re-query.
    this.broadcastQuery();
    const queryInterval = this.opts.queryIntervalMs ?? 30_000;
    this.queryTimer = setInterval(() => this.broadcastQuery(), queryInterval);

    // Periodic GC for stale peers.
    const gcInterval = this.opts.gcIntervalMs ?? 60_000;
    this.gcTimer = setInterval(() => this.gc(), gcInterval);
  }

  async stop(): Promise<void> {
    if (!this.started) return;
    this.started = false;
    if (this.queryTimer) clearInterval(this.queryTimer);
    if (this.gcTimer) clearInterval(this.gcTimer);
    this.mdns?.destroy();
    this.mdns = undefined;
    for (const peer of this.peerMap.values()) {
      this.emit({ type: "peer-down", deviceId: peer.deviceId });
    }
    this.peerMap.clear();
  }

  peers(): Peer[] {
    return Array.from(this.peerMap.values());
  }

  subscribe(listener: (e: DiscoveryEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private broadcastQuery(): void {
    if (!this.mdns) return;
    try {
      this.mdns.query({
        questions: [{ name: MDNS_SERVICE_TYPE, type: "PTR" }],
      });
    } catch (err) {
      this.emit({ type: "error", message: `mDNS query failed: ${String(err)}` });
    }

    // If we're advertising too, respond unsolicited so peers see us
    // sooner than their next query interval.
    if (this.opts.advertise) {
      try {
        this.mdns.respond({
          answers: this.buildAdvertisementAnswers(this.opts.advertise),
        });
      } catch (err) {
        this.emit({ type: "error", message: `mDNS respond failed: ${String(err)}` });
      }
    }
  }

  private buildAdvertisementAnswers(txt: AdvertisedTxt): MdnsAnswer[] {
    const instanceName = `${txt.deviceId}.${MDNS_SERVICE_TYPE}`;
    return [
      // PTR: service-type → instance-name
      { name: MDNS_SERVICE_TYPE, type: "PTR", data: instanceName, ttl: 120 },
      // SRV: instance-name → host/port
      {
        name: instanceName,
        type: "SRV",
        data: { port: txt.port, target: `${txt.deviceId}.local` },
        ttl: 120,
      },
      // TXT: instance-name → key/value pairs
      {
        name: instanceName,
        type: "TXT",
        data: this.encodeTxt(txt),
        ttl: 120,
      },
    ];
  }

  private encodeTxt(txt: AdvertisedTxt): string[] {
    return [
      `dvaiVersion=${txt.dvaiVersion}`,
      `deviceId=${txt.deviceId}`,
      `deviceName=${txt.deviceName}`,
      `models=${txt.models.join(",")}`,
      `capability=${JSON.stringify(txt.capability)}`,
      `port=${txt.port}`,
      `secure=${txt.secure ? "1" : "0"}`,
    ];
  }

  private onResponse(response: MdnsResponse): void {
    const all = [...response.answers, ...(response.additionals ?? [])];
    let srv: MdnsAnswer | undefined;
    let txt: MdnsAnswer | undefined;
    for (const a of all) {
      if (a.type === "SRV" && String(a.name).endsWith(MDNS_SERVICE_TYPE)) srv = a;
      if (a.type === "TXT" && String(a.name).endsWith(MDNS_SERVICE_TYPE)) txt = a;
    }
    if (!srv || !txt) return;

    const decoded = this.decodeTxt(txt.data);
    if (!decoded || decoded.deviceId === this.opts.selfDeviceId) return;

    const srvData = srv.data as { port: number; target: string };
    const baseUrl = `${decoded.secure ? "https" : "http"}://${srvData.target}:${srvData.port}/v1`;

    const peer: Peer = {
      deviceId: decoded.deviceId,
      deviceName: decoded.deviceName,
      dvaiVersion: decoded.dvaiVersion,
      baseUrl,
      loadedModels: decoded.models,
      capability: decoded.capability,
      via: "mdns",
      secure: decoded.secure,
      lastSeenAt: Date.now(),
    };

    const existing = this.peerMap.get(peer.deviceId);
    this.peerMap.set(peer.deviceId, peer);
    if (!existing) {
      this.emit({ type: "peer-up", peer });
    }
  }

  private decodeTxt(raw: unknown): AdvertisedTxt | undefined {
    let lines: string[];
    if (Array.isArray(raw)) {
      lines = raw.map((b) => (Buffer.isBuffer(b) ? b.toString("utf8") : String(b)));
    } else if (Buffer.isBuffer(raw)) {
      lines = raw.toString("utf8").split("\n");
    } else if (typeof raw === "string") {
      lines = raw.split("\n");
    } else {
      return undefined;
    }
    const map: Record<string, string> = {};
    for (const line of lines) {
      const eq = line.indexOf("=");
      if (eq < 0) continue;
      map[line.slice(0, eq)] = line.slice(eq + 1);
    }
    if (!map.deviceId || !map.dvaiVersion) return undefined;
    let capability: Record<string, number> = {};
    try {
      capability = JSON.parse(map.capability ?? "{}");
    } catch {
      // bad TXT — keep going with empty capability map
    }
    return {
      dvaiVersion: map.dvaiVersion,
      deviceId: map.deviceId,
      deviceName: map.deviceName ?? map.deviceId,
      models: map.models ? map.models.split(",").filter(Boolean) : [],
      capability,
      port: Number.parseInt(map.port ?? "0", 10),
      secure: map.secure === "1",
    };
  }

  private gc(): void {
    const ttl = this.opts.peerTtlMs ?? 90_000;
    const cutoff = Date.now() - ttl;
    for (const [id, peer] of this.peerMap) {
      if (peer.lastSeenAt < cutoff) {
        this.peerMap.delete(id);
        this.emit({ type: "peer-down", deviceId: id });
      }
    }
  }

  private emit(e: DiscoveryEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(e);
      } catch (err) {
        console.error("[DVAI/discovery] listener threw:", err);
      }
    }
  }
}

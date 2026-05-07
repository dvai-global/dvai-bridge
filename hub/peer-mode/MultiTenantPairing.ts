/**
 * Phase 4 — DVAI Hub Multi-Tenant Pairing.
 *
 * The v3.0 `@dvai-bridge/core` `PairingStore` is single-tenant: one
 * library instance per app, one set of pairings. The Hub's job is to
 * serve *many* mobile apps from the same machine, so it has to keep
 * each app's pairings, capability cache, and audit log isolated. A
 * "tenant" here is identified by an opaque appId (typically a bundle
 * id like `com.example.chatapp`) that the requesting peer announces
 * during handshake.
 *
 * Layout on disk:
 *
 *   {storeDir}/
 *     apps/
 *       {appId}/
 *         pairings.json          — list of Pairing rows
 *         cache.json             — capability cache for this app's models
 *         audit.log              — append-only NDJSON, 30-day rolling
 *
 * The Flavor 2 (developer-fork) build sets `allowedAppIds: [their-app]`
 * to lock the Hub down to a single app — pairings from any other
 * appId are rejected before approval is even surfaced to the user.
 */

import { promises as fs } from "node:fs";
import * as path from "node:path";
import { randomBytes } from "node:crypto";

/* -------------------------------------------------------------------------- */
/* Types — kept structurally compatible with @dvai-bridge/core's Pairing      */
/* but extended with tenant + audit fields the multi-tenant store owns.       */
/* -------------------------------------------------------------------------- */

export interface PairingRequest {
  /** Stable per-install ID of the requesting peer. */
  peerDeviceId: string;
  /** Friendly name for the user prompt. */
  peerDeviceName: string;
  /** App identifier (bundle id) — required for tenant isolation. */
  appId: string;
  /** Friendly app name for the user prompt. */
  appName?: string;
  /** SemVer of the dvai-bridge that issued the request. */
  dvaiVersion: string;
}

export interface Pairing {
  appId: string;
  peerDeviceId: string;
  peerDeviceName: string;
  appName?: string;
  /** Shared 256-bit pairing key (base64-url). */
  pairingKey: string;
  pairedAt: number;
  lastUsedAt: number;
  via: "lan-handshake" | "rendezvous-qr";
}

export interface OffloadAudit {
  /** ISO timestamp. */
  ts: string;
  appId: string;
  peerDeviceId: string;
  /** Engine that served the request (e.g. "builtin" / "ollama"). */
  engine: string;
  /** Model id as the *requestor* asked for (verbatim). */
  requestedModel: string;
  /** Model id the engine actually served (may differ via substitution). */
  servedModel: string;
  /** "exact" / "substituted" / "refuse". */
  outcome: "exact" | "substituted" | "refuse";
  /** Reason — only meaningful for substituted/refuse. */
  reason?: string;
  /** Duration in ms. */
  durationMs?: number;
}

export interface MultiTenantPairingOptions {
  /** Root directory where per-app state lives. Created if absent. */
  storeDir: string;
  /**
   * If set, only these appIds are permitted to pair. Any other appId is
   * rejected synchronously (no UI prompt fires). Used by the Flavor 2
   * developer-fork build.
   */
  allowedAppIds?: string[];
  /**
   * UI hook the Hub calls when a *new* pairing-request needs approval.
   * Returning `true` writes the new pairing; `false` rejects it. The
   * caller (PeerMode) is responsible for presenting the user prompt.
   */
  onPairingRequest: (request: PairingRequest) => Promise<boolean>;
  /** Days of inactivity before a pairing expires (default 30). */
  expireAfterDays?: number;
  /** Days of audit-log retention (default 30). */
  auditRetentionDays?: number;
}

const DEFAULT_EXPIRE_DAYS = 30;
const DEFAULT_AUDIT_DAYS = 30;
const PAIRING_KEY_BYTES = 32; // 256-bit

/* -------------------------------------------------------------------------- */
/* Implementation                                                             */
/* -------------------------------------------------------------------------- */

export class MultiTenantPairing {
  private readonly storeDir: string;
  private readonly allowedAppIds: ReadonlySet<string> | null;
  private readonly onPairingRequest: (req: PairingRequest) => Promise<boolean>;
  private readonly expireAfterDays: number;
  private readonly auditRetentionDays: number;

  constructor(opts: MultiTenantPairingOptions) {
    this.storeDir = opts.storeDir;
    this.allowedAppIds = opts.allowedAppIds && opts.allowedAppIds.length > 0
      ? new Set(opts.allowedAppIds)
      : null;
    this.onPairingRequest = opts.onPairingRequest;
    this.expireAfterDays = opts.expireAfterDays ?? DEFAULT_EXPIRE_DAYS;
    this.auditRetentionDays = opts.auditRetentionDays ?? DEFAULT_AUDIT_DAYS;
  }

  /**
   * Returns the existing pairing for (appId, peerDeviceId) if present
   * and unexpired; otherwise calls `onPairingRequest` to ask the user
   * and persists the result if approved.
   *
   * Throws when:
   *   - `request.appId` is not in `allowedAppIds` (Flavor 2 lockdown).
   *   - The user denies approval (the caller catches and surfaces a
   *     handshake-rejected response to the peer).
   */
  async approveOrFetch(request: PairingRequest): Promise<Pairing> {
    if (this.allowedAppIds && !this.allowedAppIds.has(request.appId)) {
      throw new MultiTenantPairingError(
        "app_not_allowed",
        `appId "${request.appId}" is not in the allowedAppIds list.`,
      );
    }

    const existing = await this.findPairing(request.appId, request.peerDeviceId);
    if (existing && !this.isExpired(existing)) {
      // Touch lastUsedAt so the pairing stays alive.
      existing.lastUsedAt = Date.now();
      await this.savePairing(existing);
      return existing;
    }

    const approved = await this.onPairingRequest(request);
    if (!approved) {
      throw new MultiTenantPairingError("denied", "User denied the pairing request.");
    }

    const pairing: Pairing = {
      appId: request.appId,
      peerDeviceId: request.peerDeviceId,
      peerDeviceName: request.peerDeviceName,
      pairingKey: generatePairingKey(),
      pairedAt: Date.now(),
      lastUsedAt: Date.now(),
      via: "lan-handshake",
      ...(request.appName !== undefined ? { appName: request.appName } : {}),
    };
    await this.savePairing(pairing);
    return pairing;
  }

  /** Revoke a single pairing. Idempotent — succeeds when no such pairing exists. */
  async revoke(appId: string, peerDeviceId: string): Promise<void> {
    const list = await this.listForApp(appId);
    const next = list.filter((p) => p.peerDeviceId !== peerDeviceId);
    if (next.length === list.length) return; // not found
    await this.writeAppFile(appId, "pairings.json", JSON.stringify(next, null, 2));
  }

  /** Revoke every pairing for an app. */
  async revokeAll(appId: string): Promise<void> {
    await this.writeAppFile(appId, "pairings.json", "[]");
  }

  /** Return every pairing for one app. Empty array if the app has none. */
  async listForApp(appId: string): Promise<Pairing[]> {
    return this.readAppPairings(appId);
  }

  /** Return every pairing across every app. */
  async listAll(): Promise<Pairing[]> {
    const apps = await this.listAppIds();
    const out: Pairing[] = [];
    for (const appId of apps) {
      out.push(...(await this.readAppPairings(appId)));
    }
    return out;
  }

  /** Append an audit-log entry. The log auto-trims to `auditRetentionDays`. */
  async recordAudit(appId: string, entry: OffloadAudit): Promise<void> {
    if (entry.appId !== appId) {
      // Defensive — caller passed a mismatched audit record.
      throw new MultiTenantPairingError(
        "audit_app_mismatch",
        `Audit appId ${entry.appId} doesn't match recordAudit appId ${appId}.`,
      );
    }
    await this.ensureAppDir(appId);
    const file = this.appFile(appId, "audit.log");
    const line = JSON.stringify(entry) + "\n";
    await fs.appendFile(file, line, "utf8");
    // Lazy GC — read the log, drop expired entries, rewrite. Cheap because
    // entries are append-only and the retention window is bounded.
    await this.gcAuditLog(appId);
  }

  /** Read the audit log for one app, optionally limited to the latest N entries. */
  async getAppAudit(appId: string, limit?: number): Promise<OffloadAudit[]> {
    const file = this.appFile(appId, "audit.log");
    let raw: string;
    try {
      raw = await fs.readFile(file, "utf8");
    } catch {
      return [];
    }
    const lines = raw.split("\n").filter((l) => l.trim().length > 0);
    const entries: OffloadAudit[] = [];
    for (const line of lines) {
      try {
        entries.push(JSON.parse(line) as OffloadAudit);
      } catch {
        // skip malformed lines
      }
    }
    if (limit !== undefined && entries.length > limit) {
      return entries.slice(entries.length - limit);
    }
    return entries;
  }

  /**
   * Look up a pairing by (appId, peerDeviceId). Used by handshake-verify
   * paths that need the shared pairingKey. Returns undefined when absent
   * OR expired (caller treats both the same way: re-handshake required).
   */
  async findActivePairing(
    appId: string,
    peerDeviceId: string,
  ): Promise<Pairing | undefined> {
    const p = await this.findPairing(appId, peerDeviceId);
    if (!p) return undefined;
    return this.isExpired(p) ? undefined : p;
  }

  /* -------------------------------------------------------------- */
  /* Internals                                                      */
  /* -------------------------------------------------------------- */

  private async findPairing(appId: string, peerDeviceId: string): Promise<Pairing | undefined> {
    const all = await this.readAppPairings(appId);
    return all.find((p) => p.peerDeviceId === peerDeviceId);
  }

  private async savePairing(pairing: Pairing): Promise<void> {
    const all = await this.readAppPairings(pairing.appId);
    const idx = all.findIndex((p) => p.peerDeviceId === pairing.peerDeviceId);
    if (idx >= 0) {
      all[idx] = pairing;
    } else {
      all.push(pairing);
    }
    await this.writeAppFile(pairing.appId, "pairings.json", JSON.stringify(all, null, 2));
  }

  private async readAppPairings(appId: string): Promise<Pairing[]> {
    const file = this.appFile(appId, "pairings.json");
    try {
      const raw = await fs.readFile(file, "utf8");
      const parsed: unknown = JSON.parse(raw);
      if (!Array.isArray(parsed)) return [];
      return parsed as Pairing[];
    } catch {
      return [];
    }
  }

  private isExpired(p: Pairing): boolean {
    const ageMs = Date.now() - p.lastUsedAt;
    return ageMs > this.expireAfterDays * 24 * 60 * 60 * 1000;
  }

  private async listAppIds(): Promise<string[]> {
    const dir = path.join(this.storeDir, "apps");
    try {
      const entries = await fs.readdir(dir, { withFileTypes: true });
      return entries.filter((e) => e.isDirectory()).map((e) => e.name);
    } catch {
      return [];
    }
  }

  private async ensureAppDir(appId: string): Promise<void> {
    const dir = path.join(this.storeDir, "apps", sanitizeAppId(appId));
    await fs.mkdir(dir, { recursive: true });
  }

  private appFile(appId: string, name: string): string {
    return path.join(this.storeDir, "apps", sanitizeAppId(appId), name);
  }

  private async writeAppFile(
    appId: string,
    name: string,
    contents: string,
  ): Promise<void> {
    await this.ensureAppDir(appId);
    await fs.writeFile(this.appFile(appId, name), contents, "utf8");
  }

  private async gcAuditLog(appId: string): Promise<void> {
    const cutoff = Date.now() - this.auditRetentionDays * 24 * 60 * 60 * 1000;
    const file = this.appFile(appId, "audit.log");
    let raw: string;
    try {
      raw = await fs.readFile(file, "utf8");
    } catch {
      return;
    }
    const lines = raw.split("\n").filter((l) => l.trim().length > 0);
    const kept: string[] = [];
    let droppedAny = false;
    for (const line of lines) {
      try {
        const entry = JSON.parse(line) as OffloadAudit;
        if (new Date(entry.ts).getTime() >= cutoff) {
          kept.push(line);
        } else {
          droppedAny = true;
        }
      } catch {
        // malformed line — drop
        droppedAny = true;
      }
    }
    if (droppedAny) {
      await fs.writeFile(file, kept.join("\n") + (kept.length > 0 ? "\n" : ""), "utf8");
    }
  }
}

/* -------------------------------------------------------------------------- */
/* Helpers                                                                    */
/* -------------------------------------------------------------------------- */

export class MultiTenantPairingError extends Error {
  readonly code: "app_not_allowed" | "denied" | "audit_app_mismatch";
  constructor(code: MultiTenantPairingError["code"], message: string) {
    super(message);
    this.name = "MultiTenantPairingError";
    this.code = code;
  }
}

/** appIds may include `.` and other path-unfriendly chars; replace with `_`. */
function sanitizeAppId(appId: string): string {
  return appId.replace(/[^a-zA-Z0-9._-]/g, "_");
}

/** 256-bit cryptographically-random pairing key, base64-url encoded. */
function generatePairingKey(): string {
  return base64UrlEncode(randomBytes(PAIRING_KEY_BYTES));
}

function base64UrlEncode(buf: Buffer): string {
  return buf
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

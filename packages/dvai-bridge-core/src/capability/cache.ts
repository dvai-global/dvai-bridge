/**
 * Persistent storage of capability scores + the device identifier.
 * Concrete adapters per runtime — browser uses IndexedDB; Node uses
 * the filesystem under XDG_CACHE_HOME / %LOCALAPPDATA% / ~/.cache.
 *
 * Native SDKs (iOS / Android / .NET) supply their own platform-
 * appropriate adapter via the same interface.
 */

import type { CapabilityCache, CapabilityCacheKey, CapabilityScore } from "./types.js";

/* -------------------------------------------------------------------------- */
/* In-memory adapter — fallback / testing                                     */
/* -------------------------------------------------------------------------- */

export class InMemoryCapabilityCache implements CapabilityCache {
  private readonly map = new Map<string, CapabilityScore>();

  async get(key: CapabilityCacheKey): Promise<CapabilityScore | undefined> {
    return this.map.get(this.keyOf(key));
  }
  async set(score: CapabilityScore): Promise<void> {
    this.map.set(this.keyOf({ modelId: score.modelId, libraryVersion: score.libraryVersion }), score);
  }
  async list(): Promise<CapabilityScore[]> {
    return Array.from(this.map.values());
  }
  async clear(): Promise<void> {
    this.map.clear();
  }
  private keyOf(k: CapabilityCacheKey): string {
    return `${k.libraryVersion}::${k.modelId}`;
  }
}

/* -------------------------------------------------------------------------- */
/* Browser adapter — IndexedDB                                                */
/* -------------------------------------------------------------------------- */

const DB_NAME = "dvai-bridge";
const STORE_NAME = "capability-v1";
const META_STORE_NAME = "meta-v1";

export class IndexedDBCapabilityCache implements CapabilityCache {
  private dbPromise?: Promise<IDBDatabase>;

  private openDb(): Promise<IDBDatabase> {
    if (!this.dbPromise) {
      this.dbPromise = new Promise<IDBDatabase>((resolve, reject) => {
        const req = indexedDB.open(DB_NAME, 1);
        req.onupgradeneeded = () => {
          const db = req.result;
          if (!db.objectStoreNames.contains(STORE_NAME)) {
            db.createObjectStore(STORE_NAME);
          }
          if (!db.objectStoreNames.contains(META_STORE_NAME)) {
            db.createObjectStore(META_STORE_NAME);
          }
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      });
    }
    return this.dbPromise;
  }

  async get(key: CapabilityCacheKey): Promise<CapabilityScore | undefined> {
    const db = await this.openDb();
    return await new Promise<CapabilityScore | undefined>((resolve, reject) => {
      const tx = db.transaction(STORE_NAME, "readonly");
      const req = tx.objectStore(STORE_NAME).get(this.keyOf(key));
      req.onsuccess = () => resolve(req.result as CapabilityScore | undefined);
      req.onerror = () => reject(req.error);
    });
  }

  async set(score: CapabilityScore): Promise<void> {
    const db = await this.openDb();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE_NAME, "readwrite");
      tx.objectStore(STORE_NAME).put(score, this.keyOf({ modelId: score.modelId, libraryVersion: score.libraryVersion }));
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  async list(): Promise<CapabilityScore[]> {
    const db = await this.openDb();
    return await new Promise<CapabilityScore[]>((resolve, reject) => {
      const tx = db.transaction(STORE_NAME, "readonly");
      const req = tx.objectStore(STORE_NAME).getAll();
      req.onsuccess = () => resolve(req.result as CapabilityScore[]);
      req.onerror = () => reject(req.error);
    });
  }

  async clear(): Promise<void> {
    const db = await this.openDb();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE_NAME, "readwrite");
      tx.objectStore(STORE_NAME).clear();
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  /** Reads a small key/value blob (used for the persistent device ID). */
  async getMeta(key: string): Promise<string | undefined> {
    const db = await this.openDb();
    return await new Promise<string | undefined>((resolve, reject) => {
      const tx = db.transaction(META_STORE_NAME, "readonly");
      const req = tx.objectStore(META_STORE_NAME).get(key);
      req.onsuccess = () => resolve(req.result as string | undefined);
      req.onerror = () => reject(req.error);
    });
  }
  async setMeta(key: string, value: string): Promise<void> {
    const db = await this.openDb();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(META_STORE_NAME, "readwrite");
      tx.objectStore(META_STORE_NAME).put(value, key);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  private keyOf(k: CapabilityCacheKey): string {
    return `${k.libraryVersion}::${k.modelId}`;
  }
}

/* -------------------------------------------------------------------------- */
/* Node FS adapter                                                            */
/* -------------------------------------------------------------------------- */

interface CacheFile {
  deviceId: string;
  scores: Record<string, CapabilityScore>;
}

export class NodeFsCapabilityCache implements CapabilityCache {
  private readonly cachePath: string;
  private cache?: CacheFile;

  constructor(cachePath?: string) {
    this.cachePath = cachePath ?? defaultCachePath();
  }

  private async load(): Promise<CacheFile> {
    if (this.cache) return this.cache;
    const fs = await import("node:fs/promises");
    const path = await import("node:path");
    try {
      const raw = await fs.readFile(this.cachePath, "utf8");
      this.cache = JSON.parse(raw) as CacheFile;
    } catch {
      // file doesn't exist or unparseable — start fresh.
      this.cache = { deviceId: "", scores: {} };
    }
    // Ensure parent dir exists for future writes.
    await fs.mkdir(path.dirname(this.cachePath), { recursive: true });
    return this.cache;
  }

  private async save(): Promise<void> {
    if (!this.cache) return;
    const fs = await import("node:fs/promises");
    await fs.writeFile(this.cachePath, JSON.stringify(this.cache, null, 2), "utf8");
  }

  async get(key: CapabilityCacheKey): Promise<CapabilityScore | undefined> {
    const c = await this.load();
    return c.scores[this.keyOf(key)];
  }
  async set(score: CapabilityScore): Promise<void> {
    const c = await this.load();
    c.scores[this.keyOf({ modelId: score.modelId, libraryVersion: score.libraryVersion })] = score;
    await this.save();
  }
  async list(): Promise<CapabilityScore[]> {
    const c = await this.load();
    return Object.values(c.scores);
  }
  async clear(): Promise<void> {
    const c = await this.load();
    c.scores = {};
    await this.save();
  }
  async getDeviceId(): Promise<string> {
    const c = await this.load();
    return c.deviceId;
  }
  async setDeviceId(id: string): Promise<void> {
    const c = await this.load();
    c.deviceId = id;
    await this.save();
  }

  private keyOf(k: CapabilityCacheKey): string {
    return `${k.libraryVersion}::${k.modelId}`;
  }
}

function defaultCachePath(): string {
  // Cross-platform sane default. We can't use top-level await for
  // node:os; build the path inline using process.env at construction time.
  if (typeof globalThis.process !== "undefined") {
    const env = globalThis.process.env;
    const home = env.HOME ?? env.USERPROFILE ?? ".";
    if (env.LOCALAPPDATA) {
      return `${env.LOCALAPPDATA}/dvai-bridge/capability.json`;
    }
    if (env.XDG_CACHE_HOME) {
      return `${env.XDG_CACHE_HOME}/dvai-bridge/capability.json`;
    }
    return `${home}/.cache/dvai-bridge/capability.json`;
  }
  return "./.dvai-bridge-capability.json";
}

/* -------------------------------------------------------------------------- */
/* Factory                                                                    */
/* -------------------------------------------------------------------------- */

export function createCapabilityCache(): CapabilityCache {
  if (typeof indexedDB !== "undefined") {
    return new IndexedDBCapabilityCache();
  }
  if (typeof globalThis.process !== "undefined" && globalThis.process.versions?.node) {
    return new NodeFsCapabilityCache();
  }
  // Fallback for unknown runtimes (workers without IndexedDB, etc.) —
  // memory only. Capability scores won't survive a reload.
  return new InMemoryCapabilityCache();
}

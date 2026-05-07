/**
 * Pairing storage adapters. Mirrors capability/cache.ts shape — same
 * runtimes, same per-runtime impls, same default-cache-path resolution.
 */

import type { Pairing, PairingStore } from "./types.js";

/** In-memory adapter (testing + browser-without-IndexedDB fallback). */
export class InMemoryPairingStore implements PairingStore {
  private readonly map = new Map<string, Pairing>();

  async get(peerDeviceId: string): Promise<Pairing | undefined> {
    return this.map.get(peerDeviceId);
  }
  async set(p: Pairing): Promise<void> {
    this.map.set(p.peerDeviceId, p);
  }
  async list(): Promise<Pairing[]> {
    return Array.from(this.map.values());
  }
  async remove(peerDeviceId: string): Promise<void> {
    this.map.delete(peerDeviceId);
  }
  async clear(): Promise<void> {
    this.map.clear();
  }
}

/* -------------------------------------------------------------------------- */
/* Browser — IndexedDB                                                        */
/* -------------------------------------------------------------------------- */

const DB_NAME = "dvai-bridge";
const STORE_NAME = "pairings-v1";

export class IndexedDBPairingStore implements PairingStore {
  private dbPromise?: Promise<IDBDatabase>;

  private openDb(): Promise<IDBDatabase> {
    if (!this.dbPromise) {
      this.dbPromise = new Promise<IDBDatabase>((resolve, reject) => {
        const req = indexedDB.open(DB_NAME, 1);
        req.onupgradeneeded = () => {
          const db = req.result;
          if (!db.objectStoreNames.contains(STORE_NAME)) {
            db.createObjectStore(STORE_NAME, { keyPath: "peerDeviceId" });
          }
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      });
    }
    return this.dbPromise;
  }

  async get(peerDeviceId: string): Promise<Pairing | undefined> {
    const db = await this.openDb();
    return await new Promise((resolve, reject) => {
      const req = db.transaction(STORE_NAME, "readonly").objectStore(STORE_NAME).get(peerDeviceId);
      req.onsuccess = () => resolve(req.result as Pairing | undefined);
      req.onerror = () => reject(req.error);
    });
  }
  async set(p: Pairing): Promise<void> {
    const db = await this.openDb();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE_NAME, "readwrite");
      tx.objectStore(STORE_NAME).put(p);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }
  async list(): Promise<Pairing[]> {
    const db = await this.openDb();
    return await new Promise((resolve, reject) => {
      const req = db.transaction(STORE_NAME, "readonly").objectStore(STORE_NAME).getAll();
      req.onsuccess = () => resolve(req.result as Pairing[]);
      req.onerror = () => reject(req.error);
    });
  }
  async remove(peerDeviceId: string): Promise<void> {
    const db = await this.openDb();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE_NAME, "readwrite");
      tx.objectStore(STORE_NAME).delete(peerDeviceId);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
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
}

/* -------------------------------------------------------------------------- */
/* Node FS adapter                                                            */
/* -------------------------------------------------------------------------- */

export class NodeFsPairingStore implements PairingStore {
  private readonly cachePath: string;
  private cache?: Record<string, Pairing>;

  constructor(cachePath?: string) {
    this.cachePath = cachePath ?? defaultPairingsPath();
  }

  private async load(): Promise<Record<string, Pairing>> {
    if (this.cache) return this.cache;
    const fs = await import("node:fs/promises");
    const path = await import("node:path");
    try {
      const raw = await fs.readFile(this.cachePath, "utf8");
      this.cache = JSON.parse(raw) as Record<string, Pairing>;
    } catch {
      this.cache = {};
    }
    await fs.mkdir(path.dirname(this.cachePath), { recursive: true });
    return this.cache;
  }

  private async save(): Promise<void> {
    if (!this.cache) return;
    const fs = await import("node:fs/promises");
    await fs.writeFile(this.cachePath, JSON.stringify(this.cache, null, 2), "utf8");
  }

  async get(peerDeviceId: string): Promise<Pairing | undefined> {
    const c = await this.load();
    return c[peerDeviceId];
  }
  async set(p: Pairing): Promise<void> {
    const c = await this.load();
    c[p.peerDeviceId] = p;
    await this.save();
  }
  async list(): Promise<Pairing[]> {
    const c = await this.load();
    return Object.values(c);
  }
  async remove(peerDeviceId: string): Promise<void> {
    const c = await this.load();
    delete c[peerDeviceId];
    await this.save();
  }
  async clear(): Promise<void> {
    this.cache = {};
    await this.save();
  }
}

function defaultPairingsPath(): string {
  if (typeof globalThis.process !== "undefined") {
    const env = globalThis.process.env;
    const home = env.HOME ?? env.USERPROFILE ?? ".";
    if (env.LOCALAPPDATA) return `${env.LOCALAPPDATA}/dvai-bridge/pairings.json`;
    if (env.XDG_CACHE_HOME) return `${env.XDG_CACHE_HOME}/dvai-bridge/pairings.json`;
    return `${home}/.cache/dvai-bridge/pairings.json`;
  }
  return "./.dvai-bridge-pairings.json";
}

export function createPairingStore(): PairingStore {
  if (typeof indexedDB !== "undefined") return new IndexedDBPairingStore();
  if (typeof globalThis.process !== "undefined" && globalThis.process.versions?.node) {
    return new NodeFsPairingStore();
  }
  return new InMemoryPairingStore();
}

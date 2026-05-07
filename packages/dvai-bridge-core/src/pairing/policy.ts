/**
 * Pairing decision flow. Coordinates the host-app `onPairingRequest`
 * callback (which surfaces a UI prompt) with the persistent store.
 *
 * Default behaviour (no callback supplied): deny all incoming pairings.
 * That's the safe fallback — apps that haven't wired UI shouldn't
 * accidentally accept random LAN devices.
 */

import { generatePairingKey } from "./handshake.js";
import type { Pairing, PairingStore } from "./types.js";

export interface PairingPolicyOptions {
  store: PairingStore;
  /** Host-app callback that returns user's approve/deny. */
  onPairingRequest?: (peerDeviceId: string, peerDeviceName: string) => Promise<boolean>;
  /** Pairing TTL in days. Default 30. */
  expireAfterDays?: number;
}

export interface IncomingHandshake {
  peerDeviceId: string;
  peerDeviceName: string;
  via: "lan-handshake" | "rendezvous-qr";
}

export class PairingPolicy {
  constructor(private readonly opts: PairingPolicyOptions) {}

  /**
   * Get an existing pairing, applying TTL expiry. Returns undefined
   * if the pairing is missing or expired.
   */
  async getActive(peerDeviceId: string): Promise<Pairing | undefined> {
    const existing = await this.opts.store.get(peerDeviceId);
    if (!existing) return undefined;
    const ttlMs = (this.opts.expireAfterDays ?? 30) * 24 * 60 * 60 * 1000;
    if (Date.now() - existing.lastUsedAt > ttlMs) {
      await this.opts.store.remove(peerDeviceId);
      return undefined;
    }
    return existing;
  }

  /**
   * Process an incoming pairing request. If we already have an active
   * pairing for this peer, reuse it (and bump lastUsedAt). Otherwise
   * call the host-app's onPairingRequest hook to ask for approval.
   *
   * Returns the pairing key (base64-url) on approval; throws otherwise.
   */
  async approveOrFetch(req: IncomingHandshake): Promise<Pairing> {
    const existing = await this.getActive(req.peerDeviceId);
    if (existing) {
      existing.lastUsedAt = Date.now();
      await this.opts.store.set(existing);
      return existing;
    }

    const callback = this.opts.onPairingRequest;
    const approved = callback ? await callback(req.peerDeviceId, req.peerDeviceName) : false;
    if (!approved) {
      throw new Error(
        `[DVAI/pairing] denied: peer ${req.peerDeviceId} (${req.peerDeviceName})${callback ? "" : " (no onPairingRequest callback supplied)"}`,
      );
    }

    const fresh: Pairing = {
      peerDeviceId: req.peerDeviceId,
      peerDeviceName: req.peerDeviceName,
      pairingKey: generatePairingKey(),
      pairedAt: Date.now(),
      lastUsedAt: Date.now(),
      via: req.via,
    };
    await this.opts.store.set(fresh);
    return fresh;
  }

  /** Mark a pairing as used (bumps lastUsedAt). */
  async touch(peerDeviceId: string): Promise<void> {
    const existing = await this.opts.store.get(peerDeviceId);
    if (!existing) return;
    existing.lastUsedAt = Date.now();
    await this.opts.store.set(existing);
  }

  async revoke(peerDeviceId: string): Promise<void> {
    await this.opts.store.remove(peerDeviceId);
  }
}

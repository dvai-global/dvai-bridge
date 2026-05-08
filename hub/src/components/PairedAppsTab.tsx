// Task 7b — Paired Apps tab.
//
// Lists every paired peer grouped by appId. Each row carries a Revoke
// button; each app group carries a Revoke-all button. The list refreshes
// on focus + every 10s.

import { useCallback, useEffect, useState } from "react";
import { api, type Pairing } from "../api/index.js";
import { PerAppConfig } from "./PerAppConfig.js";

export function PairedAppsTab(): JSX.Element {
  const [pairings, setPairings] = useState<Pairing[]>([]);
  const [busy, setBusy] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      setPairings(await api.getPairings());
    } catch {
      // sidecar warming
    }
  }, []);

  useEffect(() => {
    refresh();
    const t = window.setInterval(refresh, 10_000);
    return () => window.clearInterval(t);
  }, [refresh]);

  const handleRevoke = async (appId: string, peerDeviceId: string) => {
    setBusy(`${appId}:${peerDeviceId}`);
    try {
      await api.revokePairing(appId, peerDeviceId);
      await refresh();
    } finally {
      setBusy(null);
    }
  };

  const groups = groupBy(pairings, (p) => p.appId);

  return (
    <section>
      <h2>Paired Apps</h2>

      {pairings.length === 0 && (
        <p className="hint">
          No pairings yet. The first time a paired-mobile-app's
          dvai-bridge instance asks this Hub to take a request, you'll
          see an approval prompt and the pairing will appear here.
        </p>
      )}

      {Object.entries(groups).map(([appId, peers]) => (
        <div key={appId} className="group">
          <header>
            <h3>{peers[0]?.appName ?? appId}</h3>
            <code>{appId}</code>
            <span className="meta">{peers.length} device{peers.length === 1 ? "" : "s"}</span>
          </header>

          {/* v3.1.x scaffold: per-app pairing-mode + rate-limit + revoke-all. */}
          <PerAppConfig
            appId={appId}
            pairingCount={peers.length}
            onRevokedAll={refresh}
          />

          <table>
            <thead>
              <tr>
                <th>Device</th>
                <th>Paired</th>
                <th>Last seen</th>
                <th>Via</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {peers.map((p) => {
                const key = `${p.appId}:${p.peerDeviceId}`;
                return (
                  <tr key={key}>
                    <td>
                      <strong>{p.peerDeviceName}</strong>
                      <br />
                      <code className="dim">{p.peerDeviceId}</code>
                    </td>
                    <td>{formatDate(p.pairedAt)}</td>
                    <td>{formatDate(p.lastUsedAt)}</td>
                    <td>{p.via}</td>
                    <td>
                      <button
                        disabled={busy === key}
                        onClick={() => handleRevoke(p.appId, p.peerDeviceId)}
                      >
                        {busy === key ? "Revoking…" : "Revoke"}
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      ))}
    </section>
  );
}

function groupBy<T, K extends string>(arr: T[], keyFn: (t: T) => K): Record<K, T[]> {
  const out = {} as Record<K, T[]>;
  for (const item of arr) {
    const k = keyFn(item);
    if (!out[k]) out[k] = [];
    out[k].push(item);
  }
  return out;
}

function formatDate(ms: number): string {
  if (!ms) return "—";
  const d = new Date(ms);
  return d.toLocaleString(undefined, {
    year: "2-digit",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

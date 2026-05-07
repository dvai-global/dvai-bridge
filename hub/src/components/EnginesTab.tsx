// Task 7d — Engines tab.
//
// Lists every external-engine adapter the Hub knows about. Each shows
// its detection state, cached-model count, last-enumeration timestamp.
// "Rescan" forces re-enumeration; the per-engine on/off toggle is
// wired via set_engine_enabled (the underlying state lands in v3.2 —
// for now toggling re-detects).

import { useCallback, useEffect, useState } from "react";
import { api, type EngineSummary } from "../api/index.js";

export function EnginesTab(): JSX.Element {
  const [engines, setEngines] = useState<EngineSummary[]>([]);
  const [busy, setBusy] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      setEngines(await api.getEngines());
    } catch {
      // sidecar warming
    }
  }, []);

  useEffect(() => {
    refresh();
    const t = window.setInterval(refresh, 15_000);
    return () => window.clearInterval(t);
  }, [refresh]);

  const handleRescan = async (name?: string) => {
    setBusy(name ?? "all");
    try {
      await api.invalidateEngineCache(name);
      await refresh();
    } finally {
      setBusy(null);
    }
  };

  const handleToggle = async (name: string, enabled: boolean) => {
    setBusy(name);
    try {
      await api.setEngineEnabled(name, enabled);
      await refresh();
    } finally {
      setBusy(null);
    }
  };

  return (
    <section>
      <h2>External Engines</h2>
      <p className="hint">
        Hub can route paired-mobile-app requests to whichever engine
        on this machine has the requested model cached. Each adapter
        is opt-in; the Hub never auto-enables anything that wasn't
        already running on your network port.
      </p>
      <div className="actions">
        <button onClick={() => void handleRescan()} disabled={busy !== null}>
          {busy === "all" ? "Rescanning…" : "Rescan all"}
        </button>
      </div>
      <table>
        <thead>
          <tr>
            <th>Engine</th>
            <th>Detected</th>
            <th>Cached models</th>
            <th>Last enumerated</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {engines.map((e) => (
            <tr key={e.name}>
              <td><strong>{e.name}</strong></td>
              <td>
                {e.detected ? (
                  <><span className="dot ok" /> Yes</>
                ) : (
                  <><span className="dot off" /> No</>
                )}
              </td>
              <td>{e.modelCount}</td>
              <td>{e.lastEnumeratedAt ? formatDate(e.lastEnumeratedAt) : "—"}</td>
              <td>
                <button
                  disabled={busy === e.name}
                  onClick={() => void handleToggle(e.name, !e.detected)}
                >
                  {busy === e.name ? "…" : e.detected ? "Disable" : "Enable"}
                </button>
                <button
                  disabled={busy === e.name}
                  onClick={() => void handleRescan(e.name)}
                  style={{ marginLeft: 8 }}
                >
                  Rescan
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}

function formatDate(ms: number): string {
  return new Date(ms).toLocaleTimeString();
}

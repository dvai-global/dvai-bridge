// Task 7f — Logs tab.
//
// Per-app audit log view. The user picks an app from the dropdown; the
// table renders the last 200 entries. "Export JSON" downloads the full
// log for that app.

import { useCallback, useEffect, useMemo, useState } from "react";
import { api, type OffloadAudit, type Pairing } from "../api/index.js";

export function LogsTab(): JSX.Element {
  const [pairings, setPairings] = useState<Pairing[]>([]);
  const [selectedAppId, setSelectedAppId] = useState<string>("");
  const [entries, setEntries] = useState<OffloadAudit[]>([]);
  const [loading, setLoading] = useState<boolean>(false);

  // Load app list once.
  useEffect(() => {
    void (async () => {
      try {
        const ps = await api.getPairings();
        setPairings(ps);
        if (ps.length > 0 && !selectedAppId) {
          setSelectedAppId(ps[0]!.appId);
        }
      } catch {
        // sidecar warming
      }
    })();
    // intentionally only on mount; refresh button below covers re-fetch
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const refresh = useCallback(async () => {
    if (!selectedAppId) return;
    setLoading(true);
    try {
      const audit = await api.getAuditLog(selectedAppId, 200);
      setEntries(audit.reverse()); // newest first
    } finally {
      setLoading(false);
    }
  }, [selectedAppId]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const apps = useMemo(() => {
    const set = new Map<string, string>();
    for (const p of pairings) {
      if (!set.has(p.appId)) set.set(p.appId, p.appName ?? p.appId);
    }
    return Array.from(set.entries());
  }, [pairings]);

  const handleExport = async () => {
    if (!selectedAppId) return;
    const all = await api.getAuditLog(selectedAppId);
    const blob = new Blob([JSON.stringify(all, null, 2)], {
      type: "application/json",
    });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `dvai-hub-audit-${safe(selectedAppId)}.json`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <section>
      <h2>Logs</h2>
      <p className="hint">
        Per-app audit log of every offload request the Hub served (or
        refused). 30-day rolling retention. Export JSON for forensics.
      </p>

      {apps.length === 0 ? (
        <p className="hint">No apps have paired yet — no audit entries.</p>
      ) : (
        <>
          <div className="actions">
            <label>
              App:&nbsp;
              <select
                value={selectedAppId}
                onChange={(e) => setSelectedAppId(e.target.value)}
              >
                {apps.map(([id, name]) => (
                  <option key={id} value={id}>{name} ({id})</option>
                ))}
              </select>
            </label>
            <button onClick={() => void refresh()} disabled={loading}>
              {loading ? "Loading…" : "Refresh"}
            </button>
            <button onClick={() => void handleExport()} disabled={!selectedAppId}>
              Export JSON
            </button>
          </div>

          <table>
            <thead>
              <tr>
                <th>Time</th>
                <th>Engine</th>
                <th>Requested</th>
                <th>Served</th>
                <th>Outcome</th>
                <th>Reason</th>
                <th>ms</th>
              </tr>
            </thead>
            <tbody>
              {entries.length === 0 && (
                <tr>
                  <td colSpan={7} className="hint">No entries (yet).</td>
                </tr>
              )}
              {entries.map((e, i) => (
                <tr key={`${e.ts}-${i}`}>
                  <td>{formatTime(e.ts)}</td>
                  <td>{e.engine}</td>
                  <td><code className="dim">{e.requestedModel}</code></td>
                  <td><code className="dim">{e.servedModel}</code></td>
                  <td className={outcomeClass(e.outcome)}>{e.outcome}</td>
                  <td>{e.reason ?? "—"}</td>
                  <td>{e.durationMs ?? "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </section>
  );
}

function formatTime(iso: string): string {
  try {
    return new Date(iso).toLocaleString(undefined, {
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
  } catch {
    return iso;
  }
}

function outcomeClass(outcome: string): string {
  if (outcome === "exact") return "ok";
  if (outcome === "substituted") return "warn";
  return "err";
}

function safe(s: string): string {
  return s.replace(/[^A-Za-z0-9._-]/g, "_");
}

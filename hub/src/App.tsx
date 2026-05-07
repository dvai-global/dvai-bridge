/**
 * DVAI Hub — root component.
 *
 * Layout:
 *   - left rail with tab buttons (Status / Paired Apps / Models / Engines / Settings / Logs)
 *   - top right: live status pill + version
 *   - main pane: active tab
 *
 * Pairing-approval modal lives at the App level so it can intercept
 * incoming pairing-request events regardless of which tab is open.
 */

import { useEffect, useState } from "react";
import {
  api,
  onPairingRequest,
  onOffloadServed,
  type PairingRequestEnvelope,
  type PeerModeStatus,
} from "./api/index.js";
import { StatusTab } from "./components/StatusTab.js";
import { PairedAppsTab } from "./components/PairedAppsTab.js";
import { ModelsTab } from "./components/ModelsTab.js";
import { EnginesTab } from "./components/EnginesTab.js";
import { SettingsTab } from "./components/SettingsTab.js";
import { LogsTab } from "./components/LogsTab.js";
import { PairingApprovalModal } from "./components/PairingApprovalModal.js";

type TabId = "status" | "paired" | "models" | "engines" | "settings" | "logs";

const TABS: Array<{ id: TabId; label: string }> = [
  { id: "status", label: "Status" },
  { id: "paired", label: "Paired Apps" },
  { id: "models", label: "Models" },
  { id: "engines", label: "Engines" },
  { id: "settings", label: "Settings" },
  { id: "logs", label: "Logs" },
];

export function App(): JSX.Element {
  const [tab, setTab] = useState<TabId>("status");
  const [status, setStatus] = useState<PeerModeStatus | null>(null);
  const [pendingPairings, setPendingPairings] = useState<PairingRequestEnvelope[]>([]);

  // Poll status every 5s (cheap; sidecar call is local).
  useEffect(() => {
    let mounted = true;
    const refresh = async () => {
      try {
        const s = await api.getStatus();
        if (mounted) setStatus(s);
      } catch {
        // Sidecar not yet up — retry on the next tick.
      }
    };
    refresh();
    const t = window.setInterval(refresh, 5_000);
    return () => {
      mounted = false;
      window.clearInterval(t);
    };
  }, []);

  // Subscribe to pairing-request notifications from the sidecar.
  useEffect(() => {
    let unlistenP: (() => void) | undefined;
    let unlistenA: (() => void) | undefined;
    onPairingRequest((env) => {
      setPendingPairings((prev) => [...prev, env]);
    }).then((u) => {
      unlistenP = u;
    });
    onOffloadServed(() => {
      // Audit ledger badge — for v3.1 rc1 we just refresh on demand.
    }).then((u) => {
      unlistenA = u;
    });
    return () => {
      unlistenP?.();
      unlistenA?.();
    };
  }, []);

  const handlePairingResponse = async (requestId: string, approved: boolean) => {
    await api.respondToPairing(requestId, approved);
    setPendingPairings((prev) => prev.filter((r) => r.requestId !== requestId));
  };

  return (
    <div className="hub-app">
      <aside className="rail">
        <div className="brand">
          <h1>DVAI Hub</h1>
          <span className="version">v3.1.0</span>
        </div>
        <nav>
          {TABS.map((t) => (
            <button
              key={t.id}
              className={tab === t.id ? "tab active" : "tab"}
              onClick={() => setTab(t.id)}
            >
              {t.label}
            </button>
          ))}
        </nav>
        <div className="status-pill">
          {status?.running ? (
            <>
              <span className="dot ok" /> Running
            </>
          ) : (
            <>
              <span className="dot off" /> Stopped
            </>
          )}
        </div>
      </aside>
      <main className="pane">
        {tab === "status" && <StatusTab status={status} />}
        {tab === "paired" && <PairedAppsTab />}
        {tab === "models" && <ModelsTab />}
        {tab === "engines" && <EnginesTab />}
        {tab === "settings" && <SettingsTab />}
        {tab === "logs" && <LogsTab />}
      </main>
      {pendingPairings.length > 0 && (
        <PairingApprovalModal
          requests={pendingPairings}
          onRespond={handlePairingResponse}
        />
      )}
    </div>
  );
}

/**
 * DVAI Hub — root component.
 */

import { useEffect, useState } from "react";
import {
  Activity,
  AppWindow,
  Cpu,
  ClipboardList,
  LayoutDashboard,
  LogOut,
  Settings,
  User,
} from "lucide-react";
import {
  api,
  onPairingRequest,
  onOffloadServed,
  type PairingRequestEnvelope,
  type PeerModeStatus,
} from "./api/index.js";
import { StatusTab } from "./components/StatusTab.js";
import { PairedAppsTab } from "./components/PairedAppsTab.js";
import { EnginesModelsTab } from "./components/EnginesModelsTab.js";
import { SettingsTab } from "./components/SettingsTab.js";
import { LogsTab } from "./components/LogsTab.js";
import { PairingApprovalModal } from "./components/PairingApprovalModal.js";

type TabId = "status" | "paired" | "models" | "settings" | "logs";

const MAIN_TABS: Array<{ id: TabId; label: string; icon: any }> = [
  { id: "status", label: "Status", icon: LayoutDashboard },
  { id: "paired", label: "Paired Apps", icon: AppWindow },
  { id: "models", label: "Engines & Models", icon: Cpu },
  { id: "settings", label: "Settings", icon: Settings },
  { id: "logs", label: "Logs", icon: ClipboardList },
];

export function App(): React.JSX.Element {
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

  const activeTabLabel = MAIN_TABS.find((t) => t.id === tab)?.label;

  return (
    <div className="flex h-screen w-screen overflow-hidden bg-background text-on-surface">
      {/* Sidebar */}
      <aside className="glass-sidebar w-64 flex flex-col p-6 z-50">
        <div className="mb-10 px-2">
          <h2 className="text-2xl font-bold text-primary tracking-tighter">DVAI Hub</h2>
          <p className="text-[10px] uppercase tracking-[0.2em] text-on-surface-variant/50 font-semibold">
            Distributed Utility v3.2.1
          </p>
        </div>

        <nav className="flex flex-col gap-1 flex-1">
          {MAIN_TABS.filter(t => t.id !== 'settings' && t.id !== 'logs').map((t) => (
            <button
              key={t.id}
              className={tab === t.id ? "nav-item-active" : "nav-item"}
              onClick={() => setTab(t.id)}
            >
              <t.icon size={20} />
              <span className="text-sm font-medium">{t.label}</span>
            </button>
          ))}
          
          <div className="h-px bg-white/5 my-4 mx-2"></div>
          
          <button
            className={tab === "logs" ? "nav-item-active" : "nav-item"}
            onClick={() => setTab("logs")}
          >
            <ClipboardList size={20} />
            <span className="text-sm font-medium">Logs</span>
          </button>
        </nav>

        <div className="mt-auto flex flex-col gap-1">
          <button
            className={tab === "settings" ? "nav-item-active" : "nav-item"}
            onClick={() => setTab("settings")}
          >
            <Settings size={20} />
            <span className="text-sm font-medium">Settings</span>
          </button>

          <div className="mt-4 pt-4 border-t border-white/5 flex items-center gap-3 px-2">
            <div className="w-10 h-10 rounded-full bg-primary/10 flex items-center justify-center text-primary border border-primary/20">
              <User size={20} />
            </div>
            <div className="flex flex-col flex-1 min-w-0">
              <span className="text-[10px] font-bold text-on-surface-variant/50 uppercase tracking-wider">Administrator</span>
              <span className="text-xs font-bold text-on-surface truncate">Local Node</span>
            </div>
          </div>
        </div>
      </aside>

      {/* Main Content */}
      <main className="flex-1 flex flex-col min-w-0 relative">
        {/* Top Navbar */}
        <header className="glass-navbar h-16 flex items-center justify-between px-8 z-40">
          <h1 className="text-xl font-bold text-primary tracking-tight">{activeTabLabel}</h1>
          <div className="flex items-center gap-4">
             <div className="flex items-center gap-2 px-3 py-1.5 rounded-full bg-secondary/10 border border-secondary/20">
               <div className={`w-2 h-2 rounded-full ${status?.running ? 'bg-secondary animate-pulse' : 'bg-on-surface-variant/30'}`}></div>
               <span className="text-[10px] font-bold text-secondary uppercase tracking-widest">{status?.running ? 'Live' : 'Offline'}</span>
             </div>
            <button 
              className="w-10 h-10 flex items-center justify-center rounded-xl hover:bg-white/5 text-on-surface-variant hover:text-primary transition-all active:scale-90" 
              title="Logout"
              aria-label="Logout"
            >
              <LogOut size={20} />
            </button>
          </div>
        </header>

        {/* Content Area */}
        <div className="flex-1 overflow-y-auto p-8 custom-scrollbar">
          <div className="max-w-6xl mx-auto w-full pb-12">
            {tab === "status" && <StatusTab status={status} />}
            {tab === "paired" && <PairedAppsTab />}
            {tab === "models" && <EnginesModelsTab />}
            {tab === "settings" && <SettingsTab />}
            {tab === "logs" && <LogsTab />}
          </div>
        </div>

        {/* Background Decorative Elements */}
        <div className="fixed inset-0 -z-10 pointer-events-none">
          <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[800px] h-[800px] bg-primary/5 rounded-full blur-[120px]" />
          <div className="absolute top-[20%] right-[10%] w-[400px] h-[400px] bg-secondary/5 rounded-full blur-[100px]" />
        </div>
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

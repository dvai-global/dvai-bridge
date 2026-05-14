import { useCallback, useEffect, useState } from "react";
import { 
  Smartphone, 
  Trash2, 
  Loader2, 
  LayoutGrid, 
  List,
  Calendar,
  Clock,
  Wifi,
  ExternalLink,
  ChevronRight
} from "lucide-react";
import { api, type Pairing } from "../api/index.js";
import { PerAppConfig } from "./PerAppConfig.js";

type ViewMode = "grid" | "list";

export function PairedAppsTab(): React.JSX.Element {
  const [pairings, setPairings] = useState<Pairing[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [viewMode, setViewMode] = useState<ViewMode>("grid");

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
    <div className="flex flex-col gap-8">
      <header className="flex items-center justify-between">
        <div className="flex flex-col gap-1">
          <h2 className="text-2xl font-bold text-on-surface tracking-tight">Paired Applications</h2>
          <p className="text-sm text-on-surface-variant/60">Manage mobile devices authorized to use local engines.</p>
        </div>
        
        <div className="flex items-center bg-white/5 p-1 rounded-xl border border-white/5">
          <button 
            onClick={() => setViewMode("grid")}
            aria-label="Switch to Grid View"
            title="Switch to Grid View"
            className={`p-2 rounded-lg transition-all ${viewMode === "grid" ? "bg-primary text-surface shadow-lg" : "text-on-surface-variant hover:text-on-surface"}`}
          >
            <LayoutGrid size={18} />
          </button>
          <button 
            onClick={() => setViewMode("list")}
            aria-label="Switch to List View"
            title="Switch to List View"
            className={`p-2 rounded-lg transition-all ${viewMode === "list" ? "bg-primary text-surface shadow-lg" : "text-on-surface-variant hover:text-on-surface"}`}
          >
            <List size={18} />
          </button>
        </div>
      </header>

      {pairings.length === 0 && (
        <div className="flex flex-col items-center justify-center py-20 glass-card rounded-3xl border-dashed">
          <div className="w-20 h-20 rounded-full bg-primary/5 flex items-center justify-center mb-6 border border-primary/10">
            <Smartphone className="text-primary/40" size={40} />
          </div>
          <h3 className="text-xl font-bold text-on-surface mb-2">No Devices Paired</h3>
          <p className="text-sm text-on-surface-variant/60 text-center max-w-md px-10">
            Authorized mobile apps will appear here. Trigger an inference request from a mobile device on this network to start pairing.
          </p>
        </div>
      )}

      {Object.entries(groups).map(([appId, peers]) => (
        <div key={appId} className="flex flex-col gap-4 animate-in fade-in slide-in-from-bottom-4 duration-500">
          <div className="flex items-end justify-between px-2">
            <div className="flex flex-col gap-1">
              <h3 className="text-lg font-bold text-on-surface tracking-tight">{peers[0]?.appName ?? appId}</h3>
              <div className="flex items-center gap-2">
                <code className="text-[10px] bg-white/5 px-2 py-0.5 rounded text-on-surface-variant/60 border border-white/5 uppercase font-mono">{appId}</code>
                <span className="text-[10px] font-bold text-secondary uppercase tracking-widest">{peers.length} Device{peers.length === 1 ? "" : "s"}</span>
              </div>
            </div>
          </div>

          <PerAppConfig
            appId={appId}
            pairingCount={peers.length}
            onRevokedAll={refresh}
          />

          {viewMode === "grid" ? (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              {peers.map((p) => (
                <DeviceCard 
                  key={`${p.appId}:${p.peerDeviceId}`} 
                  p={p} 
                  busy={busy} 
                  onRevoke={handleRevoke} 
                />
              ))}
            </div>
          ) : (
            <div className="glass-card rounded-2xl overflow-hidden border-white/5">
              <table className="w-full text-left border-collapse">
                <thead>
                  <tr className="bg-white/5 text-[10px] font-bold uppercase tracking-widest text-on-surface-variant/40">
                    <th className="px-6 py-4">Device</th>
                    <th className="px-6 py-4">Security</th>
                    <th className="px-6 py-4">Activity</th>
                    <th className="px-6 py-4 text-right">Actions</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-white/5">
                  {peers.map((p) => (
                    <DeviceRow 
                      key={`${p.appId}:${p.peerDeviceId}`} 
                      p={p} 
                      busy={busy} 
                      onRevoke={handleRevoke} 
                    />
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

function DeviceCard({ p, busy, onRevoke }: { p: Pairing, busy: string | null, onRevoke: (a: string, d: string) => void }) {
  const key = `${p.appId}:${p.peerDeviceId}`;
  const isRevoking = busy === key;

  return (
    <div className="glass-card p-5 rounded-2xl group hover:border-primary/40 transition-all duration-300 flex flex-col gap-5">
      <div className="flex justify-between items-start">
        <div className="p-3 rounded-xl bg-white/5 text-primary group-hover:bg-primary/10 transition-colors">
          <Smartphone size={24} />
        </div>
        <button 
          onClick={() => onRevoke(p.appId, p.peerDeviceId)}
          disabled={isRevoking}
          aria-label="Revoke pairing for this device"
          title="Revoke pairing for this device"
          className="p-2 rounded-lg text-on-surface-variant/40 hover:text-error hover:bg-error/10 transition-all opacity-0 group-hover:opacity-100"
        >
          {isRevoking ? <Loader2 size={16} className="animate-spin" /> : <Trash2 size={16} />}
        </button>
      </div>

      <div className="flex flex-col gap-1">
        <h4 className="font-bold text-on-surface">{p.peerDeviceName}</h4>
        <code className="text-[10px] text-on-surface-variant/40 truncate font-mono">{p.peerDeviceId}</code>
      </div>

      <div className="grid grid-cols-2 gap-3 pt-2 border-t border-white/5">
        <div className="flex flex-col">
          <span className="text-[9px] font-bold text-on-surface-variant/30 uppercase tracking-tighter">Paired</span>
          <span className="text-[11px] text-on-surface-variant/60 font-medium">{formatShortDate(p.pairedAt)}</span>
        </div>
        <div className="flex flex-col">
          <span className="text-[9px] font-bold text-on-surface-variant/30 uppercase tracking-tighter">Last Seen</span>
          <span className="text-[11px] text-on-surface-variant/60 font-medium">{formatRelative(p.lastUsedAt)}</span>
        </div>
      </div>

      <div className="flex items-center gap-2 text-[10px] font-bold text-secondary bg-secondary/5 px-2 py-1 rounded w-fit">
        <Wifi size={10} />
        {p.via.replace('-', ' ').toUpperCase()}
      </div>
    </div>
  );
}

function DeviceRow({ p, busy, onRevoke }: { p: Pairing, busy: string | null, onRevoke: (a: string, d: string) => void }) {
  const key = `${p.appId}:${p.peerDeviceId}`;
  const isRevoking = busy === key;

  return (
    <tr className="group hover:bg-white/5 transition-colors">
      <td className="px-6 py-4">
        <div className="flex items-center gap-4">
          <div className="p-2 rounded-lg bg-white/5 text-on-surface-variant/60">
            <Smartphone size={18} />
          </div>
          <div className="flex flex-col">
            <span className="text-sm font-bold text-on-surface">{p.peerDeviceName}</span>
            <code className="text-[10px] text-on-surface-variant/40 font-mono">{p.peerDeviceId.slice(0, 8)}...</code>
          </div>
        </div>
      </td>
      <td className="px-6 py-4">
        <div className="flex flex-col gap-1">
          <div className="flex items-center gap-1.5 text-[11px] text-on-surface-variant/60">
            <Calendar size={12} className="text-on-surface-variant/30" />
            {formatDate(p.pairedAt)}
          </div>
          <div className="flex items-center gap-1.5 text-[11px] text-secondary">
            <Wifi size={12} className="text-secondary/50" />
            {p.via}
          </div>
        </div>
      </td>
      <td className="px-6 py-4">
        <div className="flex items-center gap-2 text-sm text-on-surface-variant/60">
          <Clock size={14} className="text-on-surface-variant/30" />
          {formatRelative(p.lastUsedAt)}
        </div>
      </td>
      <td className="px-6 py-4 text-right">
        <button 
          onClick={() => onRevoke(p.appId, p.peerDeviceId)}
          disabled={isRevoking}
          aria-label="Revoke pairing for this device"
          title="Revoke pairing for this device"
          className="p-2 rounded-lg text-on-surface-variant/40 hover:text-error hover:bg-error/10 transition-all opacity-0 group-hover:opacity-100"
        >
          {isRevoking ? <Loader2 size={16} className="animate-spin" /> : <Trash2 size={16} />}
        </button>
      </td>
    </tr>
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
  return new Date(ms).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function formatShortDate(ms: number): string {
  if (!ms) return "—";
  return new Date(ms).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
}

function formatRelative(ms: number): string {
  if (!ms) return "Never";
  const sec = Math.floor((Date.now() - ms) / 1000);
  if (sec < 60) return "Just now";
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  return formatDate(ms);
}

import { useEffect, useState } from "react";
import { 
  Activity, 
  Clock, 
  Cpu, 
  Globe, 
  Hash, 
  Loader2, 
  Play, 
  Square, 
  Smartphone,
  Zap,
  Info
} from "lucide-react";
import { api, type PeerModeStatus } from "../api/index.js";
import { ModelLoadProgressBar } from "./ModelLoadProgress.js";

export interface StatusTabProps {
  status: PeerModeStatus | null;
}

export function StatusTab(props: StatusTabProps): React.JSX.Element {
  const { status } = props;
  const [pairingCount, setPairingCount] = useState<number>(0);
  const [engineCount, setEngineCount] = useState<number>(0);
  const [actioning, setActioning] = useState<boolean>(false);

  useEffect(() => {
    let mounted = true;
    const refresh = async () => {
      try {
        const [pairings, engines] = await Promise.all([api.getPairings(), api.getEngines()]);
        if (!mounted) return;
        setPairingCount(pairings.length);
        setEngineCount(engines.filter((e) => e.detected).length);
      } catch {
        // sidecar warming up — silent retry on next tick
      }
    };
    refresh();
    const t = window.setInterval(refresh, 5_000);
    return () => {
      mounted = false;
      window.clearInterval(t);
    };
  }, []);

  const handleStart = async () => {
    setActioning(true);
    try {
      await api.startPeerMode();
    } finally {
      setActioning(false);
    }
  };
  
  const handleStop = async () => {
    setActioning(true);
    try {
      await api.stopPeerMode();
    } finally {
      setActioning(false);
    }
  };

  const uptime =
    status?.startedAt !== null && status?.startedAt !== undefined
      ? formatUptime(Date.now() - status.startedAt)
      : "—";

  return (
    <div className="flex flex-col gap-10">
      {/* Central Pulse Indicator */}
      <section className="flex flex-col items-center justify-center gap-6 py-10">
        <div className="relative flex items-center justify-center">
          {/* Multi-layered Pulse Rings */}
          <div className={`absolute w-48 h-48 rounded-full border border-primary/20 opacity-20 ${status?.running ? 'animate-ping' : ''}`}></div>
          <div className={`absolute w-64 h-64 rounded-full border border-primary/10 opacity-10 ${status?.running ? 'animate-pulse' : ''}`}></div>
          <div className="w-40 h-40 rounded-full glass-card pulse-glow flex flex-col items-center justify-center text-center gap-2 z-10 border-primary/30">
            <Activity className={`text-primary ${status?.running ? 'animate-pulse' : 'opacity-40'}`} size={48} />
            <div className={`w-2.5 h-2.5 rounded-full ${status?.running ? 'bg-secondary shadow-[0_0_12px_rgba(78,222,163,0.8)]' : 'bg-on-surface-variant/30'}`}></div>
          </div>
        </div>
        <div className="text-center">
          <h2 className="text-4xl font-bold text-on-surface mb-2 tracking-tight">
            System Hub {status?.running ? 'Running' : 'Stopped'}
          </h2>
          <p className="text-sm text-on-surface-variant/60 flex items-center justify-center gap-2">
            <span className={`w-2 h-2 rounded-full ${status?.running ? 'bg-secondary' : 'bg-error'}`}></span>
            {status?.running ? 'Optimal Connection Detected' : 'Server is currently offline'}
          </p>
        </div>
      </section>

      {/* Action Bar */}
      <section className="flex justify-center">
         {status?.running ? (
           <button 
            className="group relative flex items-center gap-3 px-8 py-4 rounded-full glass-card hover:bg-white/10 transition-all active:scale-95 border-primary/30"
            onClick={handleStop}
            disabled={actioning}
           >
             {actioning ? <Loader2 size={24} className="animate-spin text-primary" /> : <Square size={24} className="text-primary fill-primary/20" />}
             <span className="text-lg font-semibold text-primary">Stop Hub</span>
           </button>
         ) : (
           <button 
            className="group relative flex items-center gap-3 px-8 py-4 rounded-full bg-primary/10 border border-primary/30 hover:bg-primary/20 transition-all active:scale-95 shadow-[0_0_30px_rgba(137,206,255,0.15)]"
            onClick={handleStart}
            disabled={actioning}
           >
             {actioning ? <Loader2 size={24} className="animate-spin text-primary" /> : <Play size={24} className="text-primary fill-primary/20" />}
             <span className="text-lg font-semibold text-primary">Start Hub</span>
           </button>
         )}
      </section>

      {/* Model Loading Progress */}
      <div className="w-full max-w-2xl mx-auto">
        <ModelLoadProgressBar />
      </div>

      {/* Stats Grid */}
      <section className="grid grid-cols-1 md:grid-cols-3 gap-6">
        <div className="glass-card p-6 rounded-2xl flex flex-col gap-4 group hover:border-primary/40 transition-colors">
          <div className="flex justify-between items-start">
            <Smartphone className="text-on-surface-variant/50" size={20} />
            <span className="text-[10px] font-bold text-secondary bg-secondary/10 px-2 py-0.5 rounded-full uppercase tracking-wider">Online</span>
          </div>
          <div>
            <p className="text-[10px] font-bold text-on-surface-variant/40 uppercase tracking-widest mb-1">Connected Devices</p>
            <h3 className="text-3xl font-bold text-on-surface">{pairingCount}</h3>
          </div>
          <div className="h-1 w-full bg-white/5 rounded-full overflow-hidden">
            <div className={`h-full bg-linear-to-r from-primary to-transparent ${pairingCount > 0 ? 'w-full' : 'w-0'}`}></div>
          </div>
        </div>

        <div className="glass-card p-6 rounded-2xl flex flex-col gap-4 group hover:border-primary/40 transition-colors">
          <div className="flex justify-between items-start">
            <Zap className="text-on-surface-variant/50" size={20} />
            <span className="text-[10px] font-bold text-on-surface-variant/50 bg-white/5 px-2 py-0.5 rounded-full uppercase tracking-wider">{status?.running ? 'Active' : 'Idle'}</span>
          </div>
          <div>
            <p className="text-[10px] font-bold text-on-surface-variant/40 uppercase tracking-widest mb-1">Active Engine</p>
            <h3 className="text-3xl font-bold text-on-surface">{status?.running ? 'Peer Mode' : 'None'}</h3>
          </div>
          <div className="h-1 w-full bg-white/5 rounded-full overflow-hidden">
            <div className={`h-full bg-linear-to-r from-primary to-transparent ${status?.running ? 'w-full' : 'w-0'}`}></div>
          </div>
        </div>

        <div className="glass-card p-6 rounded-2xl flex flex-col gap-4 group hover:border-primary/40 transition-colors">
          <div className="flex justify-between items-start">
            <Cpu className="text-on-surface-variant/50" size={20} />
            <span className="text-[10px] font-bold text-on-surface-variant/50 bg-white/5 px-2 py-0.5 rounded-full uppercase tracking-wider">{engineCount} Detect</span>
          </div>
          <div>
            <p className="text-[10px] font-bold text-on-surface-variant/40 uppercase tracking-widest mb-1">Available Engines</p>
            <h3 className="text-3xl font-bold text-on-surface">{engineCount} Total</h3>
          </div>
          <div className="h-1 w-full bg-white/5 rounded-full overflow-hidden">
            <div className={`h-full bg-linear-to-r from-primary to-transparent ${engineCount > 0 ? 'w-full' : 'w-0'}`}></div>
          </div>
        </div>
      </section>

      {/* Details List */}
      <section className="glass-card p-8 rounded-2xl">
        <div className="flex items-center gap-2 mb-6">
          <Info size={18} className="text-primary" />
          <h3 className="text-sm font-bold uppercase tracking-widest text-on-surface-variant/60">System Information</h3>
        </div>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-y-6 gap-x-12">
          <div className="flex flex-col gap-1">
            <div className="flex items-center gap-2 text-on-surface-variant/50">
              <Globe size={14} />
              <span className="text-[11px] font-bold uppercase tracking-wider">Bind URL</span>
            </div>
            <code className="text-sm text-on-surface font-mono bg-white/5 px-2 py-1 rounded w-fit">{status?.baseUrl ?? "—"}</code>
          </div>

          <div className="flex flex-col gap-1">
            <div className="flex items-center gap-2 text-on-surface-variant/50">
              <Hash size={14} />
              <span className="text-[11px] font-bold uppercase tracking-wider">Port</span>
            </div>
            <span className="text-sm text-on-surface font-medium">{status?.port ?? "—"}</span>
          </div>

          <div className="flex flex-col gap-1">
            <div className="flex items-center gap-2 text-on-surface-variant/50">
              <Clock size={14} />
              <span className="text-[11px] font-bold uppercase tracking-wider">Uptime</span>
            </div>
            <span className="text-sm text-on-surface font-medium">{uptime}</span>
          </div>

          <div className="flex flex-col gap-1">
            <div className="flex items-center gap-2 text-on-surface-variant/50">
              <Smartphone size={14} />
              <span className="text-[11px] font-bold uppercase tracking-wider">Pairings</span>
            </div>
            <span className="text-sm text-on-surface font-medium">{pairingCount} apps</span>
          </div>
        </div>
      </section>

      {pairingCount === 0 && (
        <div className="p-6 rounded-xl bg-primary/5 border border-primary/20 flex gap-4 items-start">
          <Info className="text-primary shrink-0" size={20} />
          <div className="flex flex-col gap-1">
            <p className="text-sm font-semibold text-primary">Welcome to DVAI Hub</p>
            <p className="text-xs text-on-surface-variant/70 leading-relaxed">
              No mobile apps have paired yet. Open a dvai-bridge-powered app on this network and trigger 
              any inference request — the pairing prompt will fire here.
            </p>
          </div>
        </div>
      )}
    </div>
  );
}

function formatUptime(ms: number): string {
  if (ms < 0) return "—";
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
}

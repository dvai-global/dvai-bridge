import { useCallback, useEffect, useState } from "react";
import {
  Cpu,
  Zap,
  Search,
  RefreshCw,
  Box,
  Layers,
  ExternalLink,
  Loader2,
  Info
} from "lucide-react";
import { api, type EngineSummary } from "../api/index.js";
import { iconForEngineName } from "./engine-icons.js";

export function EnginesModelsTab(): React.JSX.Element {
  const [engines, setEngines] = useState<EngineSummary[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState<boolean>(false);

  const refresh = useCallback(async () => {
    setRefreshing(true);
    try {
      setEngines(await api.getEngines());
    } catch {
      // sidecar warming
    } finally {
      setRefreshing(false);
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

  const internalEngines = engines.filter(e => 
    e.name.toLowerCase().includes("transformers") || 
    e.name.toLowerCase().includes("llama.cpp") ||
    e.name.toLowerCase().includes("internal")
  );

  const externalEngines = engines.filter(e => 
    !internalEngines.some(ie => ie.name === e.name)
  );

  return (
    <div className="flex flex-col gap-10">
      <header className="flex items-center justify-between">
        <div className="flex flex-col gap-1">
          <h2 className="text-2xl font-bold text-on-surface tracking-tight">Engines & Models</h2>
          <p className="text-sm text-on-surface-variant/60">Configure inference runtimes and bridge external AI servers.</p>
        </div>
        <button 
          onClick={() => handleRescan()} 
          disabled={refreshing || busy !== null}
          className="flex items-center gap-2 px-4 py-2 rounded-xl glass-card hover:bg-white/10 transition-all active:scale-95 text-sm font-bold text-primary"
        >
          {refreshing ? <RefreshCw size={16} className="animate-spin" /> : <Search size={16} />}
          Rescan All
        </button>
      </header>

      {/* Internal Engines Section */}
      <section className="flex flex-col gap-6">
        <div className="flex items-center gap-2 px-2">
          <div className="p-1.5 rounded-lg bg-primary/10 text-primary">
            <Cpu size={16} />
          </div>
          <h3 className="text-sm font-bold uppercase tracking-widest text-on-surface-variant/60">Internal Runtimes</h3>
          <div className="h-px flex-1 bg-white/5 ml-4"></div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {internalEngines.length > 0 ? (
            internalEngines.map((e) => (
              <EngineCard 
                key={e.name} 
                engine={e} 
                isInternal={true}
                busy={busy} 
                onToggle={handleToggle} 
                onRescan={handleRescan} 
              />
            ))
          ) : (
            <div className="col-span-2 py-8 px-6 glass-card rounded-2xl flex items-center gap-4 border-dashed border-white/10">
              <Info className="text-on-surface-variant/30" size={20} />
              <p className="text-xs text-on-surface-variant/50 italic">No internal engines detected in this build.</p>
            </div>
          )}
        </div>
      </section>

      {/* External Engines Section */}
      <section className="flex flex-col gap-6">
        <div className="flex items-center gap-2 px-2">
          <div className="p-1.5 rounded-lg bg-secondary/10 text-secondary">
            <Zap size={16} />
          </div>
          <h3 className="text-sm font-bold uppercase tracking-widest text-on-surface-variant/60">External Bridges</h3>
          <div className="h-px flex-1 bg-white/5 ml-4"></div>
        </div>

        {externalEngines.length === 0 ? (
          <div className="py-12 flex flex-col items-center justify-center glass-card rounded-3xl border-dashed">
            <Box className="text-on-surface-variant/20 mb-4" size={40} />
            <p className="text-sm text-on-surface-variant/40">No external engines available.</p>
          </div>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            {externalEngines.map((e) => (
              <EngineCard 
                key={e.name} 
                engine={e} 
                isInternal={false}
                busy={busy} 
                onToggle={handleToggle} 
                onRescan={handleRescan} 
              />
            ))}
          </div>
        )}
      </section>

      <div className="p-6 rounded-2xl bg-white/5 border border-white/5 flex gap-4 items-start">
        <Info className="text-primary shrink-0" size={20} />
        <div className="flex flex-col gap-1">
          <p className="text-sm font-semibold text-on-surface">About External Engines</p>
          <p className="text-xs text-on-surface-variant/70 leading-relaxed">
            The Hub can bridge requests to local servers like Ollama, LM Studio, or vLLM. 
            Enable an engine to allow the Hub to route inference tasks to it when a paired mobile app requests a compatible model.
          </p>
        </div>
      </div>
    </div>
  );
}

function EngineCard({
  engine,
  isInternal,
  busy,
  onToggle,
  onRescan
}: {
  engine: EngineSummary,
  isInternal: boolean,
  busy: string | null,
  onToggle: (n: string, e: boolean) => void,
  onRescan: (n: string) => void
}) {
  const isBusy = busy === engine.name;
  // The toggle is rendered for every card regardless of detection
  // state so the user always sees a consistent affordance; it's
  // disabled (and visibly dimmed) when the engine is unavailable
  // so a click communicates "start the engine first, then come back."
  const toggleDisabled = !engine.detected || isBusy;
  // Resolve the brand icon for this engine. Falls back to a generic
  // Cpu / Zap glyph when the engine name doesn't match any known brand.
  const BrandIcon = iconForEngineName(engine.name);
  const FallbackIcon = isInternal ? Cpu : Zap;

  return (
    <div className={`glass-card p-5 rounded-2xl group transition-all duration-300 border-l-4 ${
      engine.enabled ? "border-l-primary shadow-lg shadow-primary/5" : (engine.detected ? "border-l-secondary/40" : "border-l-on-surface-variant/20")
    }`}>
      <div className="flex justify-between items-start mb-4">
        <div className="flex items-center gap-3">
          <div className={`p-2 rounded-lg transition-colors ${
            engine.detected ? "bg-secondary/10 text-secondary" : "bg-white/5 text-on-surface-variant/40"
          }`}>
            {BrandIcon ? <BrandIcon size={20} /> : <FallbackIcon size={20} />}
          </div>
          <div className="flex flex-col">
            <h4 className="font-bold text-on-surface group-hover:text-primary transition-colors">{engine.name}</h4>
            <div className="flex items-center gap-1.5">
              <span className={`w-1.5 h-1.5 rounded-full ${engine.detected ? 'bg-secondary animate-pulse' : 'bg-on-surface-variant/30'}`}></span>
              <span className="text-[10px] font-bold uppercase tracking-wider text-on-surface-variant/50">
                {engine.detected ? 'Detected & Online' : 'Not Found'}
              </span>
            </div>
          </div>
        </div>

        <button
          onClick={() => onToggle(engine.name, !engine.enabled)}
          disabled={toggleDisabled}
          aria-label={engine.enabled ? "Disable engine" : "Enable engine"}
          title={
            !engine.detected
              ? "Engine not available — start it on your system first"
              : engine.enabled ? "Disable engine" : "Enable engine"
          }
          className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors focus:outline-none ${
            toggleDisabled
              ? 'bg-white/5 opacity-40 cursor-not-allowed'
              : engine.enabled
                ? 'bg-primary shadow-[0_0_12px_rgba(var(--primary-rgb),0.4)]'
                : 'bg-white/10 hover:bg-white/15'
          }`}
        >
          <span className={`inline-block h-4 w-4 transform rounded-full bg-white shadow-sm transition-transform ${
            engine.enabled ? 'translate-x-6' : 'translate-x-1'
          }`} />
        </button>
      </div>

      <div className="grid grid-cols-2 gap-4 mb-5">
        <div className="flex flex-col gap-1 p-3 rounded-xl bg-white/5 border border-white/5">
          <span className="text-[9px] font-bold text-on-surface-variant/30 uppercase tracking-widest flex items-center gap-1">
            <Layers size={10} /> Models
          </span>
          <span className="text-sm font-bold text-on-surface tabular-nums">{engine.modelCount} Cached</span>
        </div>
        <div className="flex flex-col gap-1 p-3 rounded-xl bg-white/5 border border-white/5">
          <span className="text-[9px] font-bold text-on-surface-variant/30 uppercase tracking-widest flex items-center gap-1">
            <RefreshCw size={10} /> Last Scan
          </span>
          <span className="text-sm font-bold text-on-surface truncate">
            {engine.lastEnumeratedAt ? new Date(engine.lastEnumeratedAt).toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'}) : '—'}
          </span>
        </div>
      </div>

      <div className="flex items-center gap-2">
        <button
          onClick={() => onRescan(engine.name)}
          disabled={isBusy}
          className="flex-1 flex items-center justify-center gap-2 py-2 rounded-xl bg-white/5 hover:bg-white/10 text-[11px] font-bold text-on-surface-variant transition-all active:scale-95 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {isBusy && busy === engine.name ? <Loader2 size={12} className="animate-spin" /> : <RefreshCw size={12} />}
          Rescan Engine
        </button>
        {engine.detected && !isInternal && (
          <div className="p-2 rounded-xl bg-secondary/10 text-secondary">
            <ExternalLink size={14} />
          </div>
        )}
      </div>
    </div>
  );
}

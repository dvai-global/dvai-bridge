import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Loader2, CheckCircle2, AlertCircle, Download, Cpu } from "lucide-react";
import { onModelLoadProgress, type ModelLoadProgress } from "../api/index.js";

const STALE_AFTER_MS = 30_000;

interface TrackedLoad extends ModelLoadProgress {
  receivedAt: number;
}

export function ModelLoadProgressBar(): React.JSX.Element | null {
  const [loads, setLoads] = useState<Record<string, TrackedLoad>>({});

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    onModelLoadProgress((event) => {
      setLoads((prev) => {
        const next = { ...prev };
        if (event.phase === "ready") {
          next[event.modelId] = {
            ...event,
            receivedAt: Date.now(),
            progress: 1,
          };
          window.setTimeout(() => {
            setLoads((p) => {
              const { [event.modelId]: _drop, ...rest } = p;
              return rest;
            });
          }, 2500);
        } else {
          next[event.modelId] = { ...event, receivedAt: Date.now() };
        }
        return next;
      });
    }).then((u) => {
      unlisten = u;
    });
    return () => {
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    const t = window.setInterval(() => {
      setLoads((prev) => {
        const cutoff = Date.now() - STALE_AFTER_MS;
        const stillFresh = Object.entries(prev).filter(
          ([, l]) => l.receivedAt >= cutoff,
        );
        if (stillFresh.length === Object.keys(prev).length) return prev;
        return Object.fromEntries(stillFresh);
      });
    }, 5_000);
    return () => window.clearInterval(t);
  }, []);

  const entries = Object.values(loads);
  if (entries.length === 0) return null;

  return (
    <div className="flex flex-col gap-4 animate-in fade-in slide-in-from-top-4 duration-500">
      {entries.map((load) => (
        <ModelLoadRow key={load.modelId} load={load} />
      ))}
    </div>
  );
}

function ModelLoadRow({ load }: { load: TrackedLoad }): React.JSX.Element {
  const pct = Math.max(0, Math.min(1, load.progress));
  const pctLabel = (pct * 100).toFixed(1);
  
  const isError = load.phase === "error";
  const isReady = load.phase === "ready";

  const barRef = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    if (barRef.current) {
      barRef.current.style.width = `${pct * 100}%`;
    }
  }, [pct]);
  
  return (
    <div className={`glass-card p-4 rounded-xl border-l-4 transition-all duration-300 ${
      isError ? "border-l-error" : isReady ? "border-l-secondary" : "border-l-primary"
    }`}>
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-3 min-w-0">
          <div className={`p-2 rounded-lg ${
            isError ? "bg-error/10 text-error" : isReady ? "bg-secondary/10 text-secondary" : "bg-primary/10 text-primary"
          }`}>
            {load.phase === "downloading" ? <Download size={18} /> : 
             load.phase === "loading" ? <Cpu size={18} /> :
             isReady ? <CheckCircle2 size={18} /> : <AlertCircle size={18} />}
          </div>
          <div className="flex flex-col min-w-0">
            <span className="text-sm font-bold text-on-surface truncate tracking-tight">{load.modelId}</span>
            <span className="text-[10px] font-bold uppercase tracking-widest text-on-surface-variant/60">
              {phaseLabel(load.phase)} • {formatElapsed(load.timeElapsedMs)}
            </span>
          </div>
        </div>
        <div className="flex flex-col items-end">
          <span className={`text-lg font-bold tabular-nums ${
            isError ? "text-error" : isReady ? "text-secondary" : "text-primary"
          }`}>
            {pctLabel}%
          </span>
        </div>
      </div>
      
      <div className="relative h-1.5 w-full bg-white/5 rounded-full overflow-hidden">
        <div 
          ref={barRef}
          className={`absolute top-0 left-0 h-full transition-all duration-500 ease-out rounded-full ${
            isError ? "bg-error" : isReady ? "bg-secondary" : "bg-primary shadow-[0_0_10px_rgba(137,206,255,0.5)]"
          }`}
        />
      </div>

      {load.message && isError && (
        <div className="mt-3 p-2 rounded bg-error/5 border border-error/20 text-[11px] text-error leading-snug">
          {load.message}
        </div>
      )}
    </div>
  );
}

function phaseLabel(phase: ModelLoadProgress["phase"]): string {
  switch (phase) {
    case "downloading": return "Downloading";
    case "loading": return "Loading Runtime";
    case "ready": return "System Ready";
    case "error": return "Loading Failed";
  }
}

function formatElapsed(ms: number): string {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  return `${m}m ${s % 60}s`;
}

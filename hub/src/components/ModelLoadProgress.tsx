// v3.1.x scaffold — model-load progress bar.
//
// Listens to the `model-load-progress` Tauri event the sidecar emits when
// either the Transformers.js or llama.cpp backend is in a warming-up phase
// (downloading from the network, hydrating from cache, etc.). Renders a
// progress bar on the Status tab while at least one load is in flight,
// and disappears when every tracked load reaches `phase: "ready"` or
// stays idle for `STALE_AFTER_MS`.
//
// The component tracks loads by `modelId` so several concurrent loads
// (rare but possible: Transformers.js text + a vision-language model
// being warmed up at the same time) each get their own bar.
//
// Polish opportunities deliberately left for the user:
//   - styling / colours / animation
//   - friendly model-name rendering (currently shows the raw modelId)
//   - per-phase iconography
//   - long-tail error UX (currently surfaces the message inline)

import { useEffect, useState } from "react";
import { onModelLoadProgress, type ModelLoadProgress } from "../api/index.js";

const STALE_AFTER_MS = 30_000;

interface TrackedLoad extends ModelLoadProgress {
  receivedAt: number;
}

export function ModelLoadProgressBar(): JSX.Element | null {
  const [loads, setLoads] = useState<Record<string, TrackedLoad>>({});

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    onModelLoadProgress((event) => {
      setLoads((prev) => {
        const next = { ...prev };
        if (event.phase === "ready") {
          // Brief tail so the user sees "Done" before it disappears.
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
          }, 1500);
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

  // Drop loads that haven't progressed in STALE_AFTER_MS — guards against
  // a backend that crashed mid-load and never reported a terminal event.
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
    <div className="model-load-progress">
      {entries.map((load) => (
        <ModelLoadRow key={load.modelId} load={load} />
      ))}
    </div>
  );
}

function ModelLoadRow({ load }: { load: TrackedLoad }): JSX.Element {
  const pct = Math.max(0, Math.min(1, load.progress));
  const pctLabel = (pct * 100).toFixed(1);
  const elapsedLabel = formatElapsed(load.timeElapsedMs);

  return (
    <div className={`model-load-row phase-${load.phase}`}>
      <div className="model-load-meta">
        <code className="model-load-id">{load.modelId}</code>
        <span className="model-load-phase">{phaseLabel(load.phase)}</span>
        <span className="model-load-elapsed">{elapsedLabel}</span>
      </div>
      <div className="model-load-bar" role="progressbar" aria-valuenow={pct * 100} aria-valuemin={0} aria-valuemax={100}>
        <div className="model-load-bar-fill" style={{ width: `${pct * 100}%` }} />
      </div>
      <div className="model-load-pct">{pctLabel}%</div>
      {load.message && load.phase === "error" && (
        <div className="model-load-error">{load.message}</div>
      )}
    </div>
  );
}

function phaseLabel(phase: ModelLoadProgress["phase"]): string {
  switch (phase) {
    case "downloading": return "Downloading";
    case "loading": return "Loading from cache";
    case "ready": return "Ready";
    case "error": return "Failed";
  }
}

function formatElapsed(ms: number): string {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  return `${m}m ${s % 60}s`;
}

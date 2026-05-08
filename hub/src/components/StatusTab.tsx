// Task 7a — Status tab.
//
// Shows the headline operational state: peer-mode running/stopped,
// bind URL, uptime, paired-app + recent-offload counts. Provides
// start/stop control. The first-run hint surfaces when no pairings
// exist and external engines haven't been opted into.

import { useEffect, useState } from "react";
import { api, type PeerModeStatus } from "../api/index.js";
import { ModelLoadProgressBar } from "./ModelLoadProgress.js";

export interface StatusTabProps {
  status: PeerModeStatus | null;
}

export function StatusTab(props: StatusTabProps): JSX.Element {
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
    <section>
      <h2>Status</h2>

      <div className="kvgrid">
        <div className="k">State</div>
        <div className="v">
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

        <div className="k">Bind URL</div>
        <div className="v"><code>{status?.baseUrl ?? "—"}</code></div>

        <div className="k">Port</div>
        <div className="v">{status?.port ?? "—"}</div>

        <div className="k">Uptime</div>
        <div className="v">{uptime}</div>

        <div className="k">Paired apps</div>
        <div className="v">{pairingCount}</div>

        <div className="k">External engines detected</div>
        <div className="v">{engineCount}</div>
      </div>

      <div className="actions">
        <button
          className="primary"
          disabled={actioning || status?.running === true}
          onClick={handleStart}
        >
          Start
        </button>
        <button
          disabled={actioning || status?.running !== true}
          onClick={handleStop}
        >
          Pause
        </button>
      </div>

      {/* v3.1.x scaffold: surfaces Transformers.js + llama.cpp model
          load/download progress while at least one is in flight.
          Renders nothing when idle. */}
      <ModelLoadProgressBar />

      {pairingCount === 0 && (
        <div className="callout">
          <strong>Welcome to DVAI Hub.</strong> No mobile apps have paired
          yet. Open a dvai-bridge-powered app on this network and trigger
          any inference request — the pairing prompt will fire here.
        </div>
      )}
    </section>
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

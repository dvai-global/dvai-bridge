// v3.1.x scaffold — per-app config panel.
//
// Renders a row of controls per paired-app group on the Paired Apps
// tab. Three knobs:
//
//   1. Pairing mode — always-allow / require-approval / always-deny.
//      Persisted at `~/.dvai-hub/apps/<appId>/config.json` (sidecar
//      handles the FS round-trip).
//   2. Rate limit (requests / minute) — a number input. `null` (the
//      default) means unlimited. Reserved for v3.2+; the input is
//      live but the sidecar doesn't enforce yet.
//   3. Revoke all — drops every pairing under this appId in one shot.
//
// The component is a controlled-form scaffold. Submission is debounced
// in the parent caller; this component does not auto-save on each
// keystroke (the user can decide later whether to make it auto-save or
// require an explicit Save button).

import { useEffect, useState } from "react";
import {
  api,
  type PairingMode,
  type PerAppConfig as PerAppConfigType,
} from "../api/index.js";

export interface PerAppConfigProps {
  appId: string;
  /** Number of pairings under this appId — used to label the
   *  "Revoke all" button so the user knows what's being dropped. */
  pairingCount: number;
  /** Called after `setAppConfig` succeeds so the parent can refresh. */
  onConfigChanged?: (config: PerAppConfigType) => void;
  /** Called after `revokeAllPairings` succeeds so the parent can refresh. */
  onRevokedAll?: () => void;
}

const DEFAULT_CONFIG: Omit<PerAppConfigType, "appId" | "updatedAt"> = {
  pairingMode: "require-approval",
  rateLimit: { requestsPerMinute: null },
};

export function PerAppConfig(props: PerAppConfigProps): JSX.Element {
  const { appId, pairingCount, onConfigChanged, onRevokedAll } = props;
  const [config, setConfig] = useState<PerAppConfigType | null>(null);
  const [busy, setBusy] = useState<"idle" | "loading" | "saving" | "revoking">("loading");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;
    setBusy("loading");
    api.getAppConfig(appId)
      .then((c) => {
        if (!mounted) return;
        setConfig(c);
        setBusy("idle");
      })
      .catch((e) => {
        if (!mounted) return;
        setError(String(e));
        setBusy("idle");
      });
    return () => { mounted = false; };
  }, [appId]);

  const handleModeChange = async (mode: PairingMode) => {
    if (!config) return;
    setBusy("saving");
    setError(null);
    try {
      const next: Pick<PerAppConfigType, "pairingMode" | "rateLimit"> = {
        pairingMode: mode,
        rateLimit: config.rateLimit,
      };
      await api.setAppConfig(appId, next);
      const updated = { ...config, ...next, updatedAt: Date.now() };
      setConfig(updated);
      onConfigChanged?.(updated);
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy("idle");
    }
  };

  const handleRateLimitChange = async (raw: string) => {
    if (!config) return;
    const trimmed = raw.trim();
    const value = trimmed === "" ? null : Number(trimmed);
    if (value !== null && (Number.isNaN(value) || value < 0)) return;
    setBusy("saving");
    setError(null);
    try {
      const next: Pick<PerAppConfigType, "pairingMode" | "rateLimit"> = {
        pairingMode: config.pairingMode,
        rateLimit: { requestsPerMinute: value },
      };
      await api.setAppConfig(appId, next);
      const updated = { ...config, ...next, updatedAt: Date.now() };
      setConfig(updated);
      onConfigChanged?.(updated);
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy("idle");
    }
  };

  const handleRevokeAll = async () => {
    if (!confirm(`Revoke every pairing under ${appId}? Devices will need to re-pair.`)) {
      return;
    }
    setBusy("revoking");
    setError(null);
    try {
      await api.revokeAllPairings(appId);
      onRevokedAll?.();
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy("idle");
    }
  };

  if (busy === "loading" || !config) {
    return <div className="per-app-config loading">Loading config…</div>;
  }

  return (
    <div className="per-app-config">
      <div className="per-app-config-row">
        <label className="per-app-config-label">Pairing mode</label>
        <select
          value={config.pairingMode}
          disabled={busy !== "idle"}
          onChange={(e) => handleModeChange(e.target.value as PairingMode)}
        >
          <option value="always-allow">Always allow</option>
          <option value="require-approval">Require approval</option>
          <option value="always-deny">Always deny</option>
        </select>
      </div>

      <div className="per-app-config-row">
        <label className="per-app-config-label">
          Rate limit
          <span className="per-app-config-hint"> (req/min — empty = unlimited)</span>
        </label>
        <input
          type="number"
          min={0}
          step={1}
          value={config.rateLimit.requestsPerMinute ?? ""}
          disabled={busy !== "idle"}
          onChange={(e) => handleRateLimitChange(e.target.value)}
        />
      </div>

      <div className="per-app-config-row">
        <button
          className="danger"
          disabled={busy !== "idle" || pairingCount === 0}
          onClick={handleRevokeAll}
        >
          {busy === "revoking"
            ? "Revoking…"
            : `Revoke all ${pairingCount} pairing${pairingCount === 1 ? "" : "s"}`}
        </button>
      </div>

      {error && <div className="per-app-config-error">{error}</div>}
    </div>
  );
}

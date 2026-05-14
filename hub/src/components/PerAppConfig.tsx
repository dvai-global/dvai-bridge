import { useEffect, useState } from "react";
import {
  api,
  type PairingMode,
  type PerAppConfig as PerAppConfigType,
} from "../api/index.js";
import { Shield, Timer, Trash2, Loader2, AlertTriangle } from "lucide-react";

export interface PerAppConfigProps {
  appId: string;
  pairingCount: number;
  onConfigChanged?: (config: PerAppConfigType) => void;
  onRevokedAll?: () => void;
}

export function PerAppConfig(props: PerAppConfigProps): React.JSX.Element {
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
    return (
      <div className="flex items-center gap-2 text-xs text-on-surface-variant/40 animate-pulse">
        <Loader2 size={12} className="animate-spin" />
        Configuring security policy...
      </div>
    );
  }

  return (
    <div className="flex flex-wrap items-center gap-6 py-4 px-5 rounded-xl bg-white/5 border border-white/5">
      <div className="flex items-center gap-3">
        <div className="p-1.5 rounded-lg bg-primary/10 text-primary">
          <Shield size={14} />
        </div>
        <div className="flex flex-col">
          <span className="text-[10px] font-bold uppercase tracking-wider text-on-surface-variant/50">Pairing Mode</span>
          <select
            className="glass-select py-1 text-xs"
            value={config.pairingMode}
            disabled={busy !== "idle"}
            onChange={(e) => handleModeChange(e.target.value as PairingMode)}
            aria-label="Pairing Mode"
            title="Pairing Mode"
          >
            <option value="always-allow">Always Allow</option>
            <option value="require-approval">Manual Approval</option>
            <option value="always-deny">Deny All</option>
          </select>
        </div>
      </div>

      <div className="h-8 w-px bg-white/10 hidden sm:block"></div>

      <div className="flex items-center gap-3">
        <div className="p-1.5 rounded-lg bg-secondary/10 text-secondary">
          <Timer size={14} />
        </div>
        <div className="flex flex-col">
          <span className="text-[10px] font-bold uppercase tracking-wider text-on-surface-variant/50">Rate Limit</span>
          <div className="flex items-center gap-1">
            <input
              type="number"
              className="bg-transparent text-xs font-bold text-on-surface focus:outline-none w-12 border-b border-white/10 hover:border-white/30 transition-colors"
              min={0}
              step={1}
              placeholder="∞"
              value={config.rateLimit.requestsPerMinute ?? ""}
              disabled={busy !== "idle"}
              onChange={(e) => handleRateLimitChange(e.target.value)}
            />
            <span className="text-[10px] text-on-surface-variant/40 font-medium">req/min</span>
          </div>
        </div>
      </div>

      <div className="ml-auto flex items-center gap-3">
        {error && (
          <div className="flex items-center gap-1.5 text-[10px] text-error font-bold bg-error/10 px-2 py-1 rounded">
            <AlertTriangle size={10} />
            {error}
          </div>
        )}
        <button
          className={`flex items-center gap-2 px-3 py-1.5 rounded-lg text-[11px] font-bold transition-all ${
            pairingCount === 0 
              ? "opacity-30 cursor-not-allowed bg-white/5 text-on-surface-variant" 
              : "bg-error/10 text-error hover:bg-error/20 active:scale-95"
          }`}
          disabled={busy !== "idle" || pairingCount === 0}
          onClick={handleRevokeAll}
        >
          {busy === "revoking" ? <Loader2 size={12} className="animate-spin" /> : <Trash2 size={12} />}
          {busy === "revoking" ? "Revoking..." : `Revoke All ${pairingCount}`}
        </button>
      </div>
    </div>
  );
}

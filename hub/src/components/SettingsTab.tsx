import { useEffect, useState } from "react";
import {
  disable as disableAutostart,
  enable as enableAutostart,
  isEnabled as isAutostartEnabled,
} from "@tauri-apps/plugin-autostart";
import { 
  Settings, 
  Monitor, 
  Moon, 
  Sun, 
  Shield, 
  Zap, 
  HardDrive, 
  Network, 
  Lock,
  Loader2,
  Check,
  AlertCircle,
  FileCode,
  Smartphone,
  Cpu
} from "lucide-react";
import { api, type PeerModeStatus } from "../api/index.js";

type Theme = "light" | "dark" | "system";

export function SettingsTab(): React.JSX.Element {
  const [status, setStatus] = useState<PeerModeStatus | null>(null);
  const [autostart, setAutostart] = useState<boolean>(false);
  const [autoServer, setAutoServer] = useState<boolean>(() => {
    return localStorage.getItem("dvai_auto_server") === "true";
  });
  const [theme, setTheme] = useState<Theme>(() => {
    return (localStorage.getItem("dvai_theme") as Theme) || "system";
  });
  const [busy, setBusy] = useState<boolean>(false);
  const [showSuccess, setShowSuccess] = useState<string | null>(null);

  useEffect(() => {
    void (async () => {
      try {
        setStatus(await api.getStatus());
        setAutostart(await isAutostartEnabled());
      } catch {
        // sidecar warming
      }
    })();
  }, []);

  const handleToggleAutostart = async () => {
    setBusy(true);
    try {
      if (autostart) {
        await disableAutostart();
        setAutostart(false);
      } else {
        await enableAutostart();
        setAutostart(true);
      }
      triggerSuccess("autostart");
    } finally {
      setBusy(false);
    }
  };

  const handleToggleAutoServer = (val: boolean) => {
    setAutoServer(val);
    localStorage.setItem("dvai_auto_server", String(val));
    triggerSuccess("autoserver");
  };

  const handleThemeChange = (newTheme: Theme) => {
    setTheme(newTheme);
    localStorage.setItem("dvai_theme", newTheme);
    // In a real app, this would update the document class or data-theme
    triggerSuccess("theme");
  };

  const triggerSuccess = (id: string) => {
    setShowSuccess(id);
    setTimeout(() => setShowSuccess(null), 2000);
  };

  return (
    <div className="flex flex-col gap-10 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <header className="flex flex-col gap-1">
        <h2 className="text-2xl font-bold text-on-surface tracking-tight">System Settings</h2>
        <p className="text-sm text-on-surface-variant/60">Configure application behavior, appearance, and network policies.</p>
      </header>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
        {/* General Settings */}
        <section className="flex flex-col gap-6">
          <div className="flex items-center gap-2 px-2">
            <Settings size={16} className="text-primary" />
            <h3 className="text-sm font-bold uppercase tracking-widest text-on-surface-variant/60">General</h3>
          </div>

          <div className="glass-card rounded-2xl overflow-hidden divide-y divide-white/5">
            <div className="p-5 flex items-center justify-between group">
              <div className="flex flex-col gap-1">
                <span className="text-sm font-bold text-on-surface">Auto-start on Login</span>
                <span className="text-xs text-on-surface-variant/50">Launch DVAI Hub when your computer starts up.</span>
              </div>
              <button 
                onClick={handleToggleAutostart}
                disabled={busy}
                aria-label={autostart ? "Disable auto-start on login" : "Enable auto-start on login"}
                title={autostart ? "Disable auto-start on login" : "Enable auto-start on login"}
                className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors focus:outline-none ${
                  autostart ? 'bg-secondary' : 'bg-white/10'
                }`}
              >
                <span className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                  autostart ? 'translate-x-6' : 'translate-x-1'
                }`} />
              </button>
            </div>

            <div className="p-5 flex items-center justify-between group">
              <div className="flex flex-col gap-1">
                <span className="text-sm font-bold text-on-surface">Auto-start Server</span>
                <span className="text-xs text-on-surface-variant/50">Automatically start Peer Mode when the app opens.</span>
              </div>
              <button 
                onClick={() => handleToggleAutoServer(!autoServer)}
                aria-label={autoServer ? "Disable auto-start server" : "Enable auto-start server"}
                title={autoServer ? "Disable auto-start server" : "Enable auto-start server"}
                className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors focus:outline-none ${
                  autoServer ? 'bg-secondary' : 'bg-white/10'
                }`}
              >
                <span className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                  autoServer ? 'translate-x-6' : 'translate-x-1'
                }`} />
              </button>
            </div>

            <div className="p-5 flex flex-col gap-4">
              <div className="flex flex-col gap-1">
                <span className="text-sm font-bold text-on-surface">Appearance</span>
                <span className="text-xs text-on-surface-variant/50">Choose your preferred interface theme.</span>
              </div>
              <div className="grid grid-cols-3 gap-2">
                {(["light", "dark", "system"] as Theme[]).map((t) => (
                  <button
                    key={t}
                    onClick={() => handleThemeChange(t)}
                    className={`flex items-center justify-center gap-2 py-2.5 rounded-xl border transition-all text-xs font-bold capitalize ${
                      theme === t 
                        ? "bg-primary/10 border-primary text-primary" 
                        : "bg-white/5 border-transparent text-on-surface-variant/60 hover:bg-white/10"
                    }`}
                  >
                    {t === "light" && <Sun size={14} />}
                    {t === "dark" && <Moon size={14} />}
                    {t === "system" && <Monitor size={14} />}
                    {t}
                  </button>
                ))}
              </div>
            </div>
          </div>
        </section>

        {/* Network & Security */}
        <section className="flex flex-col gap-6">
          <div className="flex items-center gap-2 px-2">
            <Shield size={16} className="text-secondary" />
            <h3 className="text-sm font-bold uppercase tracking-widest text-on-surface-variant/60">Network & Security</h3>
          </div>

          <div className="glass-card rounded-2xl p-6 flex flex-col gap-6">
            <div className="flex flex-col gap-4">
              <div className="flex items-center justify-between text-[11px] font-bold uppercase tracking-wider text-on-surface-variant/40">
                <span className="flex items-center gap-1.5"><Network size={12} /> Connection Details</span>
              </div>
              <div className="space-y-3">
                <div className="flex items-center justify-between py-2 border-b border-white/5">
                  <span className="text-xs text-on-surface-variant/60">mDNS Service</span>
                  <code className="text-xs text-primary font-mono bg-primary/5 px-2 py-0.5 rounded">_dvai-bridge._tcp.local</code>
                </div>
                <div className="flex items-center justify-between py-2 border-b border-white/5">
                  <span className="text-xs text-on-surface-variant/60">Encryption</span>
                  <div className="flex items-center gap-1.5 text-xs text-secondary font-bold">
                    <Lock size={12} />
                    AES-256-GCM
                  </div>
                </div>
                <div className="flex items-center justify-between py-2 border-b border-white/5">
                  <span className="text-xs text-on-surface-variant/60">Pairing TTL</span>
                  <span className="text-xs text-on-surface font-bold">30 Days (Inactivity)</span>
                </div>
              </div>
            </div>

            <div className="flex flex-col gap-4">
              <div className="flex items-center justify-between text-[11px] font-bold uppercase tracking-wider text-on-surface-variant/40">
                <span className="flex items-center gap-1.5"><HardDrive size={12} /> Storage</span>
              </div>
              <div className="p-4 rounded-xl bg-white/5 border border-white/5 flex items-start gap-4">
                <FileCode size={20} className="text-on-surface-variant/40 shrink-0 mt-1" />
                <div className="flex flex-col gap-1 min-w-0">
                  <span className="text-xs font-bold text-on-surface">Configuration Path</span>
                  <code className="text-[10px] text-on-surface-variant/60 break-all leading-tight">
                    {window.navigator.platform.includes("Win") 
                      ? "%LOCALAPPDATA%\\dvai-hub\\settings.json" 
                      : "~/.dvai-hub/settings.json"}
                  </code>
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>

      {/* Advanced Policies */}
      <section className="flex flex-col gap-6">
        <div className="flex items-center gap-2 px-2">
          <Zap size={16} className="text-on-surface-variant/40" />
          <h3 className="text-sm font-bold uppercase tracking-widest text-on-surface-variant/60">Advanced Policies</h3>
        </div>
        
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div className="glass-card p-5 rounded-2xl flex flex-col gap-3">
             <div className="p-2 rounded-lg bg-white/5 text-on-surface-variant/60 w-fit">
               <Cpu size={16} />
             </div>
             <div className="flex flex-col gap-1">
               <span className="text-sm font-bold text-on-surface">Substitution</span>
               <p className="text-[11px] text-on-surface-variant/60 leading-relaxed">
                 Strict mode: Hub refuses requests if requested model is not found.
               </p>
             </div>
          </div>
          
          <div className="glass-card p-5 rounded-2xl flex flex-col gap-3">
             <div className="p-2 rounded-lg bg-white/5 text-on-surface-variant/60 w-fit">
               <Smartphone size={16} />
             </div>
             <div className="flex flex-col gap-1">
               <span className="text-sm font-bold text-on-surface">Peer Isolation</span>
               <p className="text-[11px] text-on-surface-variant/60 leading-relaxed">
                 Peers cannot see each other; all communication routes through the Hub.
               </p>
             </div>
          </div>

          <div className="glass-card p-5 rounded-2xl flex flex-col gap-3">
             <div className="p-2 rounded-lg bg-white/5 text-on-surface-variant/60 w-fit">
               <Shield size={16} />
             </div>
             <div className="flex flex-col gap-1">
               <span className="text-sm font-bold text-on-surface">Audit Logging</span>
               <p className="text-[11px] text-on-surface-variant/60 leading-relaxed">
                 Every served inference is logged locally for 30 days.
               </p>
             </div>
          </div>
        </div>
      </section>

      {showSuccess && (
        <div className="fixed bottom-8 right-8 animate-in slide-in-from-right-10 duration-300">
          <div className="flex items-center gap-3 px-4 py-3 rounded-2xl bg-secondary text-surface shadow-2xl shadow-secondary/20 font-bold text-sm">
            <Check size={18} />
            Settings updated successfully
          </div>
        </div>
      )}
    </div>
  );
}

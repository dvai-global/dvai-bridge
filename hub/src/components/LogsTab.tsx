import { useCallback, useEffect, useMemo, useState } from "react";
import { 
  Activity,
  ClipboardList, 
  Download, 
  RefreshCw, 
  Search, 
  Clipboard, 
  X, 
  Clock, 
  Cpu, 
  Smartphone, 
  CheckCircle2, 
  AlertCircle, 
  ArrowRight,
  Filter,
  Check,
  MoreHorizontal
} from "lucide-react";
import { api, type OffloadAudit, type Pairing } from "../api/index.js";

export function LogsTab(): React.JSX.Element {
  const [pairings, setPairings] = useState<Pairing[]>([]);
  const [selectedAppId, setSelectedAppId] = useState<string>("");
  const [entries, setEntries] = useState<OffloadAudit[]>([]);
  const [loading, setLoading] = useState<boolean>(false);
  const [selectedEntry, setSelectedEntry] = useState<OffloadAudit | null>(null);
  const [copied, setCopied] = useState<boolean>(false);

  // Load app list once.
  useEffect(() => {
    void (async () => {
      try {
        const ps = await api.getPairings();
        setPairings(ps);
        if (ps.length > 0 && !selectedAppId) {
          setSelectedAppId(ps[0]!.appId);
        }
      } catch {
        // sidecar warming
      }
    })();
  }, []);

  const refresh = useCallback(async () => {
    if (!selectedAppId) return;
    setLoading(true);
    try {
      const audit = await api.getAuditLog(selectedAppId, 200);
      setEntries(audit.reverse()); // newest first
    } finally {
      setLoading(false);
    }
  }, [selectedAppId]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const apps = useMemo(() => {
    const set = new Map<string, string>();
    for (const p of pairings) {
      if (!set.has(p.appId)) set.set(p.appId, p.appName ?? p.appId);
    }
    return Array.from(set.entries());
  }, [pairings]);

  const handleExport = async () => {
    if (!selectedAppId) return;
    const all = await api.getAuditLog(selectedAppId);
    const blob = new Blob([JSON.stringify(all, null, 2)], {
      type: "application/json",
    });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `dvai-hub-audit-${safe(selectedAppId)}.json`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const handleCopy = (text: string) => {
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="flex flex-col gap-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <header className="flex flex-col gap-1">
        <h2 className="text-2xl font-bold text-on-surface tracking-tight">Audit Logs</h2>
        <p className="text-sm text-on-surface-variant/60">Forensic ledger of all distributed inference requests processed by this Hub.</p>
      </header>

      {apps.length === 0 ? (
        <div className="py-20 flex flex-col items-center justify-center glass-card rounded-3xl border-dashed">
          <ClipboardList className="text-on-surface-variant/20 mb-4" size={48} />
          <p className="text-sm text-on-surface-variant/40 font-medium">No application activity recorded yet.</p>
        </div>
      ) : (
        <div className="flex flex-col gap-6">
          <div className="flex flex-wrap items-center justify-between gap-4 p-4 glass-card rounded-2xl">
            <div className="flex items-center gap-3">
              <div className="p-2 rounded-lg bg-primary/10 text-primary">
                <Filter size={16} />
              </div>
              <div className="flex flex-col">
                <span className="text-[10px] font-bold uppercase tracking-wider text-on-surface-variant/50">Filter by Application</span>
                <select
                  className="glass-select py-1.5 min-w-[200px]"
                  value={selectedAppId}
                  onChange={(e) => setSelectedAppId(e.target.value)}
                  aria-label="Filter by Application"
                  title="Filter by Application"
                >
                  {apps.map(([id, name]) => (
                    <option key={id} value={id}>{name} ({id.slice(0,8)}...)</option>
                  ))}
                </select>
              </div>
            </div>

            <div className="flex items-center gap-2">
              <button 
                onClick={() => void refresh()} 
                disabled={loading}
                className="flex items-center gap-2 px-4 py-2 rounded-xl bg-white/5 hover:bg-white/10 transition-all active:scale-95 text-xs font-bold text-on-surface-variant"
              >
                {loading ? <RefreshCw size={14} className="animate-spin" /> : <RefreshCw size={14} />}
                Refresh
              </button>
              <button 
                onClick={() => void handleExport()} 
                disabled={!selectedAppId}
                className="flex items-center gap-2 px-4 py-2 rounded-xl bg-primary/10 hover:bg-primary/20 transition-all active:scale-95 text-xs font-bold text-primary border border-primary/20"
              >
                <Download size={14} />
                Export JSON
              </button>
            </div>
          </div>

          <div className="glass-card rounded-2xl overflow-hidden border-white/5">
            <div className="overflow-x-auto">
              <table className="w-full text-left border-collapse">
                <thead>
                  <tr className="bg-white/5 text-[10px] font-bold uppercase tracking-widest text-on-surface-variant/40">
                    <th className="px-6 py-4">Timestamp</th>
                    <th className="px-6 py-4">Engine</th>
                    <th className="px-6 py-4">Request Flow</th>
                    <th className="px-6 py-4">Outcome</th>
                    <th className="px-6 py-4 text-right">Duration</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-white/5">
                  {entries.length === 0 && (
                    <tr>
                      <td colSpan={5} className="px-6 py-12 text-center text-sm text-on-surface-variant/40 italic">
                        No transactions recorded for this application.
                      </td>
                    </tr>
                  )}
                  {entries.map((e, i) => (
                    <tr 
                      key={`${e.ts}-${i}`} 
                      className="group hover:bg-white/5 transition-colors cursor-pointer"
                      onClick={() => setSelectedEntry(e)}
                    >
                      <td className="px-6 py-4">
                        <div className="flex items-center gap-2 text-xs text-on-surface font-medium">
                          <Clock size={12} className="text-on-surface-variant/30" />
                          {formatTime(e.ts)}
                        </div>
                      </td>
                      <td className="px-6 py-4">
                        <div className="flex items-center gap-2">
                          <Cpu size={12} className="text-primary/50" />
                          <span className="text-xs text-on-surface font-bold">{e.engine}</span>
                        </div>
                      </td>
                      <td className="px-6 py-4">
                        <div className="flex items-center gap-3">
                          <code className="text-[10px] text-on-surface-variant/60 bg-white/5 px-2 py-0.5 rounded border border-white/5">{e.requestedModel}</code>
                          <ArrowRight size={10} className="text-on-surface-variant/30" />
                          <code className="text-[10px] text-primary/70 bg-primary/5 px-2 py-0.5 rounded border border-primary/10">{e.servedModel}</code>
                        </div>
                      </td>
                      <td className="px-6 py-4">
                        <div className={`flex items-center gap-1.5 text-[10px] font-bold uppercase tracking-wider ${outcomeColor(e.outcome)}`}>
                          {e.outcome === "exact" ? <CheckCircle2 size={12} /> : <AlertCircle size={12} />}
                          {e.outcome}
                        </div>
                      </td>
                      <td className="px-6 py-4 text-right">
                        <div className="flex items-center justify-end gap-3">
                          <span className="text-xs font-bold text-on-surface tabular-nums">{e.durationMs ? `${e.durationMs}ms` : "—"}</span>
                          <button 
                            className="p-1.5 rounded-lg bg-white/5 text-on-surface-variant/20 group-hover:text-on-surface-variant/60 transition-colors"
                            aria-label="View details"
                            title="View details"
                          >
                            <MoreHorizontal size={14} />
                          </button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      )}

      {/* Detail Modal */}
      {selectedEntry && (
        <div className="fixed inset-0 z-100 flex items-center justify-center p-6 animate-in fade-in duration-300">
          <div className="absolute inset-0 bg-background/80 backdrop-blur-md" onClick={() => setSelectedEntry(null)} />
          <div className="glass-card w-full max-w-xl rounded-3xl overflow-hidden shadow-2xl relative z-10 animate-in zoom-in-95 duration-300 border-primary/20">
            <header className="p-6 border-b border-white/5 flex items-center justify-between">
              <div className="flex flex-col gap-1">
                <h3 className="text-lg font-bold text-on-surface tracking-tight">Transaction Details</h3>
                <span className="text-[10px] font-bold text-primary uppercase tracking-widest">{formatTime(selectedEntry.ts)}</span>
              </div>
              <button 
                onClick={() => setSelectedEntry(null)}
                className="p-2 rounded-xl bg-white/5 text-on-surface-variant hover:text-on-surface transition-all active:scale-90"
                aria-label="Close details"
                title="Close details"
              >
                <X size={20} />
              </button>
            </header>

            <div className="p-8 flex flex-col gap-8">
               <div className="grid grid-cols-2 gap-8">
                  <DetailItem icon={<Smartphone />} label="Origin Device" value={selectedEntry.peerDeviceId} isCode />
                  <DetailItem icon={<Cpu />} label="Inference Engine" value={selectedEntry.engine} />
                  <DetailItem 
                    icon={<Box />} 
                    label="Requested Model" 
                    value={selectedEntry.requestedModel} 
                    isCode 
                  />
                  <DetailItem 
                    icon={<CheckCircle2 />} 
                    label="Served Model" 
                    value={selectedEntry.servedModel} 
                    isCode 
                    color="text-primary"
                  />
                  <DetailItem icon={<Activity />} label="Outcome" value={selectedEntry.outcome} uppercase color={outcomeColor(selectedEntry.outcome)} />
                  <DetailItem icon={<Clock />} label="Latency" value={selectedEntry.durationMs ? `${selectedEntry.durationMs}ms` : "—"} />
               </div>

               {selectedEntry.reason && (
                 <div className="p-4 rounded-2xl bg-error/5 border border-error/10 flex flex-col gap-2">
                   <span className="text-[10px] font-bold uppercase tracking-wider text-error/60">Failure Reason</span>
                   <p className="text-sm text-error/90 font-medium leading-relaxed">{selectedEntry.reason}</p>
                 </div>
               )}

               <div className="flex flex-col gap-3 pt-4 border-t border-white/5">
                 <div className="flex items-center justify-between">
                    <span className="text-xs font-bold text-on-surface-variant/40 uppercase tracking-wider">Raw JSON Metadata</span>
                    <button 
                      onClick={() => handleCopy(JSON.stringify(selectedEntry, null, 2))}
                      className="flex items-center gap-1.5 text-[10px] font-bold text-primary hover:text-secondary transition-colors"
                    >
                      {copied ? <Check size={12} /> : <Clipboard size={12} />}
                      {copied ? "Copied" : "Copy to Clipboard"}
                    </button>
                 </div>
                 <pre className="p-4 rounded-2xl bg-black/40 text-[10px] font-mono text-on-surface-variant/80 overflow-x-auto max-h-40 custom-scrollbar border border-white/5">
                   {JSON.stringify(selectedEntry, null, 2)}
                 </pre>
               </div>
            </div>
            
            <footer className="p-6 bg-white/5 flex justify-end">
               <button 
                onClick={() => setSelectedEntry(null)}
                className="px-6 py-2.5 rounded-xl bg-primary text-surface font-bold text-sm shadow-lg shadow-primary/20 active:scale-95 transition-all"
               >
                 Close Entry
               </button>
            </footer>
          </div>
        </div>
      )}
    </div>
  );
}

function DetailItem({ icon, label, value, isCode, uppercase, color }: any) {
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-2 text-on-surface-variant/40">
        {icon && <span className="scale-75 origin-left">{icon}</span>}
        <span className="text-[10px] font-bold uppercase tracking-widest">{label}</span>
      </div>
      {isCode ? (
        <code className={`text-xs font-mono break-all px-2 py-1 rounded bg-white/5 border border-white/5 ${color ?? 'text-on-surface'}`}>{value}</code>
      ) : (
        <span className={`text-sm font-bold ${uppercase ? 'uppercase tracking-wide' : ''} ${color ?? 'text-on-surface'}`}>{value}</span>
      )}
    </div>
  );
}

function Box(props: any) {
  return (
    <svg 
      xmlns="http://www.w3.org/2000/svg" 
      width="24" height="24" 
      viewBox="0 0 24 24" 
      fill="none" 
      stroke="currentColor" 
      strokeWidth="2" 
      strokeLinecap="round" 
      strokeLinejoin="round" 
      {...props}
    >
      <path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z" />
      <path d="m3.3 7 8.7 5 8.7-5" />
      <path d="M12 22V12" />
    </svg>
  );
}

function formatTime(iso: string): string {
  try {
    return new Date(iso).toLocaleString(undefined, {
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hour12: false
    });
  } catch {
    return iso;
  }
}

function outcomeColor(outcome: string): string {
  if (outcome === "exact") return "text-secondary";
  if (outcome === "substituted") return "text-primary";
  return "text-error";
}

function safe(s: string): string {
  return s.replace(/[^A-Za-z0-9._-]/g, "_");
}

import { Shield, Smartphone, SmartphoneNfc, Check, X, ShieldAlert } from "lucide-react";
import type { PairingRequestEnvelope } from "../api/index.js";

export interface PairingApprovalModalProps {
  requests: PairingRequestEnvelope[];
  onRespond: (requestId: string, approved: boolean) => Promise<void>;
}

export function PairingApprovalModal(
  props: PairingApprovalModalProps,
): React.JSX.Element | null {
  const head = props.requests[0];
  if (!head) return null;
  const { request, requestId } = head;
  
  return (
    <div className="fixed inset-0 z-200 flex items-center justify-center p-6 animate-in fade-in duration-300">
      <div className="absolute inset-0 bg-background/60 backdrop-blur-xl" />
      
      <div className="glass-card w-full max-w-md rounded-[32px] overflow-hidden shadow-2xl relative z-10 animate-in zoom-in-95 duration-300 border-primary/20">
        <div className="p-8 flex flex-col items-center text-center gap-6">
          <div className="relative">
            <div className="absolute inset-0 bg-primary/20 blur-2xl rounded-full" />
            <div className="relative w-20 h-20 rounded-3xl bg-primary/10 border border-primary/20 flex items-center justify-center text-primary">
              <SmartphoneNfc size={40} />
            </div>
            <div className="absolute -bottom-2 -right-2 w-8 h-8 rounded-full bg-secondary text-surface flex items-center justify-center border-4 border-background shadow-lg">
              <Shield size={14} />
            </div>
          </div>

          <div className="flex flex-col gap-2">
            <h2 className="text-2xl font-bold text-on-surface tracking-tight">Pairing Request</h2>
            <p className="text-sm text-on-surface-variant/70 leading-relaxed">
              <span className="text-on-surface font-bold">{request.peerDeviceName}</span> is requesting permission to offload inference tasks.
            </p>
          </div>

          <div className="w-full p-4 rounded-2xl bg-white/5 border border-white/5 flex flex-col gap-3">
             <div className="flex items-center justify-between">
                <span className="text-[10px] font-bold text-on-surface-variant/40 uppercase tracking-widest">Application</span>
                <span className="text-xs font-bold text-primary">{request.appName ?? request.appId}</span>
             </div>
             <div className="flex items-center justify-between">
                <span className="text-[10px] font-bold text-on-surface-variant/40 uppercase tracking-widest">Protocol</span>
                <span className="text-xs font-medium text-on-surface-variant">dvai-bridge v{request.dvaiVersion}</span>
             </div>
             <div className="flex items-center justify-between">
                <span className="text-[10px] font-bold text-on-surface-variant/40 uppercase tracking-widest">Device ID</span>
                <code className="text-[10px] font-mono text-on-surface-variant/60">{request.peerDeviceId.slice(0, 12)}...</code>
             </div>
          </div>

          <div className="flex items-start gap-3 p-4 rounded-2xl bg-primary/5 border border-primary/10 text-left">
            <ShieldAlert size={18} className="text-primary shrink-0 mt-0.5" />
            <p className="text-[11px] text-on-surface-variant/70 leading-relaxed">
              By approving, you allow this device to use your local engines and models. You can manage or revoke this connection at any time in the Paired Apps tab.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-4 w-full pt-2">
            <button 
              onClick={() => props.onRespond(requestId, false)}
              className="flex items-center justify-center gap-2 py-3.5 rounded-2xl bg-white/5 hover:bg-white/10 text-on-surface font-bold transition-all active:scale-95"
            >
              <X size={18} className="text-on-surface-variant" />
              Deny
            </button>
            <button 
              onClick={() => props.onRespond(requestId, true)}
              className="flex items-center justify-center gap-2 py-3.5 rounded-2xl bg-primary text-surface font-bold transition-all active:scale-95 shadow-lg shadow-primary/20"
            >
              <Check size={18} />
              Approve
            </button>
          </div>
        </div>
        
        {props.requests.length > 1 && (
          <div className="bg-primary/10 py-2 px-4 text-center">
            <span className="text-[10px] font-bold text-primary uppercase tracking-widest">
              +{props.requests.length - 1} more pending requests
            </span>
          </div>
        )}
      </div>
    </div>
  );
}

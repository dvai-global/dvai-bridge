// Pairing-approval modal. The Hub may have multiple stacked requests
// in flight (rare but supported); the modal renders the head of the
// queue and surfaces a Approve / Deny / Always-allow set of buttons.
import type { PairingRequestEnvelope } from "../api/index.js";

export interface PairingApprovalModalProps {
  requests: PairingRequestEnvelope[];
  onRespond: (requestId: string, approved: boolean) => Promise<void>;
}

export function PairingApprovalModal(
  props: PairingApprovalModalProps,
): JSX.Element | null {
  const head = props.requests[0];
  if (!head) return null;
  const { request, requestId } = head;
  return (
    <div className="modal-backdrop">
      <div className="modal">
        <h2>Pairing request</h2>
        <p>
          <strong>{request.peerDeviceName}</strong> wants to pair with this Hub
          on behalf of{" "}
          <strong>{request.appName ?? request.appId}</strong> (dvai-bridge v
          {request.dvaiVersion}).
        </p>
        <p className="hint">
          Approving lets this device offload inference requests to your Hub.
          You can revoke the pairing any time from the Paired Apps tab.
        </p>
        <div className="modal-actions">
          <button onClick={() => props.onRespond(requestId, false)}>Deny</button>
          <button
            className="primary"
            onClick={() => props.onRespond(requestId, true)}
          >
            Approve
          </button>
        </div>
      </div>
    </div>
  );
}

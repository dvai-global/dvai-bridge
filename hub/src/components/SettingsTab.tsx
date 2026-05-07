// Task 7e — Settings tab.
//
// Read-only surface in v3.1 rc1: shows the current bind URL, mDNS
// service name, rendezvous URL, and store directory. Editing settings
// lands in v3.2 once the sidecar exposes a settings-mutation method —
// the rc1 cut keeps the surface small and explicit so users can verify
// what's running rather than tweaking it from the UI.

import { useEffect, useState } from "react";
import {
  disable as disableAutostart,
  enable as enableAutostart,
  isEnabled as isAutostartEnabled,
} from "@tauri-apps/plugin-autostart";
import { api, type PeerModeStatus } from "../api/index.js";

export function SettingsTab(): JSX.Element {
  const [status, setStatus] = useState<PeerModeStatus | null>(null);
  const [autostart, setAutostart] = useState<boolean>(false);
  const [busy, setBusy] = useState<boolean>(false);

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
    } finally {
      setBusy(false);
    }
  };

  return (
    <section>
      <h2>Settings</h2>
      <p className="hint">
        v3.1 rc1 surfaces the active settings read-only. Live editing
        lands in v3.2; for now, edit the config file directly:
      </p>
      <ul className="hint">
        <li>macOS / Linux: <code>~/.dvai-hub/settings.json</code></li>
        <li>Windows: <code>%LOCALAPPDATA%\dvai-hub\settings.json</code></li>
      </ul>
      <div className="kvgrid">
        <div className="k">Bind URL</div>
        <div className="v"><code>{status?.baseUrl ?? "—"}</code></div>

        <div className="k">Port</div>
        <div className="v">{status?.port ?? "—"}</div>

        <div className="k">mDNS service</div>
        <div className="v"><code>_dvai-bridge._tcp.local</code></div>

        <div className="k">Rendezvous URL</div>
        <div className="v">unset (LAN-only)</div>

        <div className="k">Auto-start at login</div>
        <div className="v">
          <label>
            <input
              type="checkbox"
              checked={autostart}
              disabled={busy}
              onChange={() => void handleToggleAutostart()}
            />
            &nbsp;{autostart ? "Enabled" : "Disabled"}
          </label>
        </div>

        <div className="k">External engines</div>
        <div className="v">opt-in per engine (see Engines tab)</div>

        <div className="k">Substitution policy</div>
        <div className="v">strict by default</div>

        <div className="k">Pairing TTL</div>
        <div className="v">30 days inactivity</div>

        <div className="k">Audit log retention</div>
        <div className="v">30 days rolling</div>
      </div>
    </section>
  );
}

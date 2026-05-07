// Task 7c — Models tab.
//
// Read-only list of locally-cached models the Hub itself owns. The
// model-management surface (download new models, delete cached ones)
// is intentionally minimal in v3.1 — most users get models via the
// external-engine bridge (Ollama / LM Studio / etc.). Future work
// (v3.2+) will surface a "Add Model" wizard backed by the v3.0
// downloadModel + sha256 verify substrate.

import { useEffect, useState } from "react";
import { api } from "../api/index.js";

interface UnifiedModelRow {
  engine: string;
  modelId: string;
  family: string;
  version: string | null;
  size: string;
  quant: string | null;
  type: string;
}

export function ModelsTab(): JSX.Element {
  const [rows, setRows] = useState<UnifiedModelRow[]>([]);
  const [refreshing, setRefreshing] = useState<boolean>(false);

  useEffect(() => {
    void refresh();
  }, []);

  const refresh = async () => {
    setRefreshing(true);
    try {
      // The Hub doesn't currently expose a unified "all models" command
      // (that's wired in Task 7c follow-up). For v3.1 rc1 we surface
      // the engine summaries alongside their counts; the per-engine
      // breakdown is left to the Engines tab's enumeration cache.
      const engines = await api.getEngines();
      const out: UnifiedModelRow[] = engines
        .filter((e) => e.detected)
        .map((e) => ({
          engine: e.name,
          modelId: `${e.modelCount} cached`,
          family: "—",
          version: null,
          size: "—",
          quant: null,
          type: "—",
        }));
      setRows(out);
    } finally {
      setRefreshing(false);
    }
  };

  return (
    <section>
      <h2>Models</h2>
      <p className="hint">
        Cached models surfaced via the external-engine bridge. The Hub's
        own model-download surface lands in v3.2; for now use Ollama /
        LM Studio / etc. to pre-cache models, then enable those engines
        in the Engines tab.
      </p>
      <div className="actions">
        <button onClick={() => void refresh()} disabled={refreshing}>
          {refreshing ? "Refreshing…" : "Refresh"}
        </button>
      </div>
      {rows.length === 0 ? (
        <p className="hint">
          No detected engines. Open the Engines tab to enable Ollama
          / LM Studio / vLLM / llama-server / llamafile.
        </p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Engine</th>
              <th>Cached</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.engine}>
                <td>{r.engine}</td>
                <td>{r.modelId}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}

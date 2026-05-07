// Stub for v3.1.0-rc1; Task 7a fleshes this out.
import type { PeerModeStatus } from "../api/index.js";

export function StatusTab(props: { status: PeerModeStatus | null }): JSX.Element {
  const { status } = props;
  return (
    <section>
      <h2>Status</h2>
      <pre className="placeholder">{JSON.stringify(status, null, 2)}</pre>
      <p className="hint">Status tab UI is wired in Task 7a.</p>
    </section>
  );
}

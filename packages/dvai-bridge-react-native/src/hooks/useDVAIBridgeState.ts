import { useEffect, useState } from "react";

import { DVAIBridge } from "../DVAIBridge";
import type { DVAIBridgeState, ProgressEvent } from "../types";

/**
 * Reactive view of the bridge state, polling-free, suitable for direct use
 * in functional components:
 *
 * ```tsx
 * function MyScreen() {
 *   const state = useDVAIBridgeState();
 *   if (!state.isReady) return <ActivityIndicator />;
 *   return <Text>Server: {state.baseUrl}</Text>;
 * }
 * ```
 *
 * Implementation:
 *
 *  1. On mount: fetches the initial status via {@link DVAIBridge.status}.
 *  2. Subscribes to the `"DVAIBridgeProgress"` event-emitter channel.
 *  3. On `progress` / `started` / `failed` events: stashes the event under
 *     `lastProgress` for UI hints during boot/download.
 *  4. On `completed phase=start`: re-fetches `status()` to surface
 *     the new `baseUrl` / `port` / `backend` / `modelId`.
 *  5. On `completed phase=stop`: clears the running fields.
 *
 * Cleans up the subscription on unmount.
 */
export function useDVAIBridgeState(): DVAIBridgeState {
  const [state, setState] = useState<DVAIBridgeState>({ isReady: false });

  useEffect(() => {
    let mounted = true;

    // Initial snapshot — the bridge may already be running when this hook
    // first mounts (e.g. on a screen-remount after a navigation event).
    DVAIBridge.status()
      .then((status) => {
        if (!mounted) return;
        setState((prev) => ({
          ...prev,
          isReady: status.running,
          baseUrl: status.baseUrl,
          port: status.port,
          backend: status.backend,
          modelId: status.modelId,
        }));
      })
      .catch(() => {
        // Failing here is non-fatal: surface as "not ready", let the
        // user retry via UI.
        if (mounted) setState({ isReady: false });
      });

    const subscription = DVAIBridge.addProgressListener((event: ProgressEvent) => {
      if (!mounted) return;

      // Stash every event under `lastProgress` for UI hints (progress bars,
      // loading text, etc.) regardless of kind.
      setState((prev) => ({ ...prev, lastProgress: event }));

      // On start completion: re-fetch the canonical server info.
      if (event.kind === "completed" && event.phase === "start") {
        DVAIBridge.status()
          .then((status) => {
            if (!mounted) return;
            setState((prev) => ({
              ...prev,
              isReady: status.running,
              baseUrl: status.baseUrl,
              port: status.port,
              backend: status.backend,
              modelId: status.modelId,
              // Preserve `lastProgress` from the event we just observed.
              lastProgress: prev.lastProgress,
            }));
          })
          .catch(() => {
            // No-op: the next status() poll on remount will pick this up.
          });
      }

      // On stop completion: clear the running fields immediately.
      if (event.kind === "completed" && event.phase === "stop") {
        setState((prev) => ({
          isReady: false,
          lastProgress: prev.lastProgress,
        }));
      }

      // On a `failed` event for `start`: ensure isReady stays false so
      // consumers don't render a stale running state.
      if (event.kind === "failed" && event.phase === "start") {
        setState((prev) => ({
          ...prev,
          isReady: false,
        }));
      }
    });

    return () => {
      mounted = false;
      subscription.remove();
    };
  }, []);

  return state;
}

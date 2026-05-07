/**
 * Cold-run capability probe. Runs a fixed-size completion against the
 * active backend and measures decode tok/s. Result is cached per
 * (modelId, libraryVersion) so we only pay this cost once per
 * (model, version) pair.
 */

import type { CapabilityScore } from "./types.js";

const PROBE_PROMPT = "Generate a single short sentence about clouds.";
const PROBE_MAX_TOKENS = 50;

/**
 * Generic backend interface the probe needs. The full BackendInterface
 * in DVAI is wider; we only need chatCompletion here.
 */
export interface ProbableBackend {
  chatCompletion(req: {
    messages: Array<{ role: string; content: string }>;
    max_tokens?: number;
    stream?: boolean;
  }): Promise<{
    choices: Array<{ message?: { content?: string }; text?: string }>;
    usage?: { completion_tokens?: number };
  }>;
}

export async function probeCapability(opts: {
  backend: ProbableBackend;
  modelId: string;
  libraryVersion: string;
  deviceId: string;
}): Promise<CapabilityScore> {
  const t0 = performance.now();
  const response = await opts.backend.chatCompletion({
    messages: [{ role: "user", content: PROBE_PROMPT }],
    max_tokens: PROBE_MAX_TOKENS,
    stream: false,
  });
  const elapsedSec = (performance.now() - t0) / 1000;

  // Token count: prefer the backend's own count (many backends report
  // it in usage.completion_tokens), fall back to a coarse word-count
  // approximation.
  const tokensFromUsage = response.usage?.completion_tokens;
  const text =
    response.choices[0]?.message?.content ??
    response.choices[0]?.text ??
    "";
  const tokens = tokensFromUsage ?? approximateTokenCount(text);

  // Guard against zero-time and zero-token edge cases.
  const tokPerSec = tokens > 0 && elapsedSec > 0
    ? Math.round((tokens / elapsedSec) * 10) / 10
    : 0;

  return {
    modelId: opts.modelId,
    deviceId: opts.deviceId,
    libraryVersion: opts.libraryVersion,
    tokPerSec,
    source: "probe",
    measuredAt: Date.now(),
  };
}

/**
 * Crude token-count approximation when the backend doesn't report
 * usage. Underestimates by ~25% for English text; that's fine for
 * capacity-band purposes — we'd rather under-report tok/s and offload
 * more often than over-report.
 */
function approximateTokenCount(text: string): number {
  // ~4 chars per token for English; whitespace + punctuation counted.
  return Math.max(1, Math.round(text.length / 4));
}

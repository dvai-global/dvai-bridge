# Tested models

The DVAI-Bridge Capacitor plugins are model-agnostic — anything in GGUF
form runs on `capacitor-llama`, anything in MediaPipe `.task` form runs
on `capacitor-mediapipe`. This page lists the specific models we
exercise in CI and pre-release smoke tests, organized by tier of
verification effort.

> [!NOTE]
> Some model entries below carry a *placeholder* tag where the upstream
> name has not yet been finalized at the time this document was written.
> Verify the exact HF revision before pinning into your app.

## Tier 1 — development (per-PR smoke)

Cached on the self-hosted CI runner. These models are loaded for every
PR-level smoke run on iOS / Android.

| Backend | Model | Format | ~Size | Notes |
|---|---|---|---|---|
| `capacitor-llama` | `Llama-3.2-1B-Instruct` | GGUF Q4_K_M | ~770 MB | Text completion baseline. `contextSize: 2048`, `maxTokens: 256`. |
| `capacitor-llama` (embeddings) | `bge-small-en-v1.5` | GGUF Q8_0 | ~133 MB | Started with `embeddingMode: true`. |
| `capacitor-mediapipe` | `gemma-3n-E2B-it` *(placeholder if `gemma-4-E2B-it` not yet shipped)* | `.task` | ~1.5 GB | Vision-capable variant when the E2B `.task` artifact is published. |
| `capacitor-foundation` | Apple-managed (implicit on iOS 26+) | — | 0 (zero-download) | No `modelPath`. Real-device required for full coverage; Simulator coverage is limited. |

Memory footprint at runtime is roughly **1.3–1.6× the on-disk size** for
GGUF (working buffers + KV cache scaled by `contextSize`). `.task`
artifacts are closer to **1.1–1.3×** because MediaPipe manages
memory differently.

## Tier 2 — pre-release (manual, fuller coverage)

Run against a real device in the week before tagging a release.

| Backend | Model | Format | ~Size | Notes |
|---|---|---|---|---|
| `capacitor-llama` | `Qwen2.5-1.5B-Instruct` *(or `Qwen3.5-1.5B` once shipped)* | GGUF Q4_K_M | ~1.0 GB | Multilingual smoke. |
| `capacitor-llama` | `Phi-3.5-mini-instruct` | GGUF Q4_K_M | ~2.3 GB | Long-context (128k) smoke; cap to `contextSize: 8192` on phones. |
| `capacitor-llama` | `Llama-3.2-3B-Instruct` | GGUF Q4_K_M | ~2.0 GB | Larger-text-only smoke. |
| `capacitor-llama` (vision) | `gemma-4-E2B-it` *(placeholder)* + matching mmproj | GGUF Q4_0 + mmproj | ~1.5 GB pair | Image content parts; requires `mmprojPath`. |
| `capacitor-llama` (vision flagship) | `gemma-4-E4B-it` *(placeholder)* + mmproj | GGUF Q4_K_M + mmproj | ~3.5 GB pair | Higher-quality vision; phone-RAM-class. |
| `capacitor-llama` (audio) | `Phi-4-Multimodal-Instruct` | GGUF Q4_K_M | ~7 GB | Audio + image; tablet / high-RAM phone only. |
| `capacitor-mediapipe` | `gemma-2b-it` | `.task` | ~1.3 GB | Reference MediaPipe artifact from Google's `tasks-genai` distribution. |

## Tier 3 — backend-specific real-device

| Backend | Notes |
|---|---|
| `capacitor-foundation` | Apple's curated 3B-class model. Auto-loaded on iOS 26+. Cannot run on Simulator beyond a thin smoke; tier requires a real device with the system download present. |
| `capacitor-mediapipe` (vision) | Vision-enabled Gemma `.task` variants from `tasks-genai`. Requires `visionEnabled: true` at session build-time; we wire this through `StartOptions`. |

## Recommended `start()` parameters by class

| Model class | `contextSize` | `gpuLayers` | `maxTokens` |
|---|---|---|---|
| 1B text | 2048–4096 | 99 (full) | 256 |
| 1.5–3B text | 2048 | 99 | 256 |
| 1.5B vision (image) | 4096 | 99 | 384 |
| 3.5B vision (image) | 4096 | 99 | 384 |
| 7B multimodal (audio + image) | 4096 | 99 | 384 |
| Embeddings | 512 | 99 | n/a |

`gpuLayers: 99` is "request maximum offload" — `llama.cpp` decides what
fits. Lowering it manually is rarely needed; raise the floor only if
you see the device thermal-throttling under sustained inference.

## What we deliberately don't verify

- Output quality, BLEU, or any benchmark accuracy. These tests check
  *mechanics* — load, respond, stream, free — not whether the model
  is good.
- Specific token-per-second figures. They vary too widely across
  device tiers for a per-PR gate.
- Long-running soak (>60s). Tier 2 covers a single round-trip per model;
  longer sessions are an explicit user-test exercise pre-launch.

## Curating this list

This file is the authoritative reference; updates are docs-only commits.
When upstream renames or removes a model, update both the entry above
and the matching pinned URL / sha256 in your app's distribution config.

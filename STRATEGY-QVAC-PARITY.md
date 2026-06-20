# DVAI-Bridge ⇄ QVAC parity plan

Internal strategy note. Maps capabilities QVAC ships today that DVAI-Bridge
doesn't, with a concrete plan to close each gap — without losing the
differentiators we already have over them. Not published to
bridge.deepvoiceai.co.

Snapshot: 2026-06-20.

---

## Where we agree

Both projects are *embedded local inference runtimes* — neither is a
gateway (LiteLLM) nor an end-user-installed server (Ollama / LM Studio).
Both expose an optional OpenAI-compatible HTTP surface so agentic
frameworks (LangChain, autogen, crewai, OpenAI SDKs) plug in unchanged.
Both ship multi-modal. Both offer peer-to-peer offload (QVAC's
"delegate inference to peers" ≈ our **DVAI Hub** Wi-Fi pairing). Both
have a flagship showcase desktop app (QVAC **Workbench** ≈ our **DVAI
Hub**).

## What QVAC has that we don't yet

Listed roughly by user-visible weight.

| # | QVAC capability | Status in DVAI-Bridge today |
|---|-----------------|-----------------------------|
| 1 | **Image generation** (diffusion backend) | Not present |
| 2 | **Video synthesis** (same diffusion family) | Not present |
| 3 | **Text-to-speech** (custom GGML backend) | Not present |
| 4 | **Dedicated speech-to-text** (Whisper + NVIDIA Parakeet) | Partial — we transcribe via multimodal LLMs (mtmd); no dedicated Whisper.cpp backend |
| 5 | **OCR** (ONNX Runtime) | Not present |
| 6 | **Translation** (Bergamot) | Not present (achievable via LLM, but no purpose-built path) |
| 7 | **Out-of-the-box RAG** workflow | Building blocks exist (`/v1/embeddings`); no SDK-level RAG helper |
| 8 | **Fine-tuning** in the SDK | Not present (we load pre-trained models only; LoRA adapter load is possible but not exposed) |
| 9 | **Apache 2.0 licence** | Custom "DVAI Bridge Community Licence v1.0" — source-available, restricted |
| 10 | "All-in-one SDK" framing — single install, every capability | We are split by platform (5 SDKs); each SDK is single-purpose-LLM-focused |
| 11 | **P2P native to the JS runtime** (Bare / Holepunch family) | Our Hub uses HTTP+HMAC over LAN, not a P2P substrate |
| 12 | **BCI transcription**, **VLA** (vision-language-action) | Niche; not present |
| 13 | **Tether brand / balance-sheet reach** | We're an independent label — no parity move, only patience |

## What we have that QVAC doesn't

Don't lose these in the rewrite — they're the wedge.

- **5 native SDKs** (Swift / Kotlin / Dart / TypeScript / C#) across **5 native registries** (CocoaPods / Maven Central / pub.dev / npm / NuGet). QVAC is JS-only.
- **Apple Foundation Models** (iOS 18.x system LLM) — zero-download inference on supported devices. QVAC doesn't reach this layer.
- **MLX** backend on Apple Silicon. QVAC doesn't.
- **CoreML** + **MediaPipe LLM** + **LiteRT** — native acceleration paths QVAC doesn't expose.
- **OpenAI HTTP is THE product**, not an optional wrapper — that single design choice is why any agentic framework "just works."
- **Mac Catalyst** + **.NET MAUI** path — desktop-class deployment with mobile codebase reuse.
- **Auto-recovery** loop (blank-chunk detection, generation timeout, bounded reload) — production-shaped reliability beyond a vanilla SDK.

---

## How to close each gap

Per-item, with a real engineering path. **Prioritised in the next section.**

### 1 & 2. Image + video generation
- **Backend:** [`stable-diffusion.cpp`](https://github.com/leejet/stable-diffusion.cpp) (GGML-family, mirrors our llama.cpp pattern). For Apple Silicon, **MLX-Examples Stable Diffusion**. For Android, Stable Diffusion via MediaPipe or LiteRT.
- **API surface:** OpenAI's `/v1/images/generations` is already a spec — we adopt it verbatim. Same wire-compatibility wedge as LLMs.
- **Distribution:** new `BackendKind.diffusion` enum entry; SD model files via the existing `downloadModel` flow.
- **Lift:** medium. Engine integration mirrors how we did llama.cpp; SD models are larger (~2 GB SDXL Turbo) so model-distribution UX matters.

### 3. Text-to-speech
- **Backend options:** `piper-tts` (small footprint, ONNX-based) or `tts.cpp` (GGML-style, matches stack). Mobile-native paths exist too — **AVSpeechSynthesizer** (iOS), **android.speech.tts.TextToSpeech** (Android).
- **API surface:** OpenAI's `/v1/audio/speech` spec.
- **Lift:** small-to-medium. Native paths are essentially free; an embedded engine is the differentiator.

### 4. Dedicated STT (Whisper + Parakeet-equivalent)
- **Backend:** **`whisper.cpp`** as a first-class backend (we already vendor parts of the GGML family). On mobile, also wire to **Apple Speech / SFSpeechRecognizer** and Android's `SpeechRecognizer`.
- **API surface:** OpenAI's `/v1/audio/transcriptions` and `/v1/audio/translations` specs.
- **Lift:** small. Promote what we partially support already, add a real Whisper path.

### 5. OCR
- **Backend:** **Apple Vision** on iOS, **ML Kit Text Recognition** on Android, **Tesseract** or PaddleOCR as the cross-platform fallback. ONNX Runtime where QVAC ships it.
- **API surface:** No OpenAI spec exists — define a small `/v1/vision/ocr` shape, document it as a DVAI extension.
- **Lift:** small. Mostly platform-glue.

### 6. Translation
- **Path A:** ship Bergamot models (Mozilla's offline translation engine — small, dedicated). 
- **Path B:** translate via the LLM you already have (Gemma 4 multilingual handles this).
- **API surface:** custom `/v1/translations` endpoint, or expose as a system-prompt convenience in the LLM path.
- **Lift:** small if Path B; medium for Path A (model curation).

### 7. RAG primitives
- We already ship `/v1/embeddings` — the substrate. What we're missing is an SDK helper that does chunking + embed + cosine-retrieve + context-assemble idiomatically per platform.
- **Deliverable:** `DVAIBridge.RAG` module on each SDK with: chunker (token-aware), embed-batch, vector-store interface (in-memory + Core Data / Room / SQLite implementations), retrieve-top-K, prompt-assembly. Same surface in Swift/Kotlin/Dart/TS/C#.
- **Lift:** medium. Engineering is straightforward; designing the API for parity across 5 SDKs is the work.

### 8. Fine-tuning / LoRA
- **Phase 1 (low lift):** support **loading LoRA adapters at runtime** in the llama.cpp path. Document the workflow. Users fine-tune externally (Unsloth, Axolotl) and ship the adapter.
- **Phase 2 (high lift):** in-process LoRA training. `llama.cpp` has `train-text-from-scratch` and the new finetune branch — long-running. Mobile-class fine-tuning is real on Apple Silicon and modern Android (8 GB+).
- **Lift:** Phase 1 small; Phase 2 large. Ship Phase 1 first.

### 9. Apache 2.0 licence
- **Decision-level**, not engineering. Re-licensing from the Community Licence to Apache 2.0 (or dual-licence) is a strategic call about commercial protection vs. ecosystem adoption.
- **Recommendation:** consider an Apache-2.0 *core* with a commercial-licence overlay for the orchestration/Hub layer if revenue-defence matters. Many projects do this (e.g., Elastic-style). Decoupling the licence question from the engineering plan is healthy.

### 10. "All-in-one SDK" framing
- We're structurally split per platform — that's *the* differentiator, not a weakness. But we can adopt their **internal framing**: one `DVAIBridge` import on each platform, capability switched via `BackendKind` or a sibling `Capability` enum. The marketing line becomes "one import, every capability, on every platform."
- **Lift:** zero engineering; it's a docs + naming exercise. (Part of why this v2 docs branch exists.)

### 11. P2P substrate
- Our DVAI Hub today is LAN-paired HTTP+HMAC. QVAC uses a P2P substrate (Bare/Holepunch) that doesn't require same-LAN.
- **Path:** evaluate **libp2p** (Rust core, bindings to Swift/Kotlin/Dart) or **Iroh** (Rust QUIC-based, very mobile-friendly). Adding a P2P transport behind the existing offload proxy keeps the API stable.
- **Lift:** medium-large. Worth doing if cross-network offload becomes a real customer ask; not urgent.

### 12. BCI / VLA
- Niche. Defer unless a customer signal appears.

### 13. Brand reach
- No engineering parity move. Out of scope.

---

## Suggested prioritisation

Build order, scored on **(impact × ease)**:

1. **STT (Whisper.cpp)** — high impact, small lift. Closes the most visible "we don't have Whisper" gap. Three weeks for a clean integration across SDKs.
2. **TTS** — high impact, small lift. Round-trip voice (in + out) becomes the headline.
3. **OCR via platform-native** — small lift, mostly already-present APIs on iOS/Android.
4. **RAG SDK helper module** — moderate lift, very high developer-facing value. Same surface across all 5 SDKs.
5. **Image generation (`stable-diffusion.cpp`)** — high impact, medium lift. Bigger model story than LLMs (UX work for download + cache).
6. **LoRA adapter loading (Phase 1 only)** — small lift; punches above its weight in positioning ("local fine-tunes work").
7. **Translation (LLM-based path first, Bergamot later)** — small if Path B.
8. **Video synthesis** — defer until image is shipped and demand signal exists.
9. **Apache-2.0 relicence decision** — non-engineering; revisit when commercial model is settled.
10. **P2P substrate** — only if cross-network offload is asked for; ship LAN-pairing matures first.

## What we keep saying louder

- "One import per platform, OpenAI wire on every platform."
- "Apple Foundation Models, MLX, CoreML, MediaPipe, LiteRT — runtime-picked."
- "Embedded in YOUR app. Not installed by your user. Not a gateway."

These three lines should anchor every v2 docs page above the fold.

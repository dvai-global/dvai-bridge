# Phase 2 — Multimodal completion + real-device integration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the deferred items from Phase 1 — multimodal eval (vision/audio on llama), MediaPipe LiteRT-LM migration, real-device CI — and finish them. Plus a few small contract cleanups.

**Architecture:** Patterns established in Phase 1 (DvaiHandlers protocol, bridge interfaces, mock-driven tests, mac-build.ps1 SSH workflow) carry forward unchanged. Phase 2 fills the multimodal eval gap behind those interfaces.

**Tech stack:** Swift 5.9+ / Kotlin 2.x / TS 6 / llama.cpp's mtmd API surface / Apple FoundationModels / Google MediaPipe (likely LiteRT-LM after migration).

**Branch:** `feat/phase2-multimodal` off `main`.

---

## Sub-phases

| Phase | Tasks | Scope | Risk |
|---|---|---|---|
| **2A** | 1-6 | Foundational — chips, ProgressEvent reconciliation, dep bumps | Low |
| **2B** | 7-12 | Vision + audio on capacitor-llama via mtmd_helper_eval | High (architectural) |
| **2C** | 13-15 | Real-device CI — RealModelSmokeTest skeleton, self-hosted runner wiring | Medium |
| **2D** | 16-20 | MediaPipe LiteRT-LM migration | High (architectural) |

Sub-phases are mostly independent. 2A → 2B → 2C → 2D is the recommended order; 2D can slip to Phase 3 if scope tight.

---

## Phase 2A — Foundational (Tasks 1-6)

### Task 1: ProgressEvent reconciliation

**Files:**
- Modify: `packages/dvai-bridge-capacitor/src/types.ts`
- Modify: `packages/dvai-bridge-capacitor/src/__tests__/dispatch.test.ts` (or wherever ProgressEvent shape is asserted; if nowhere, no test edit)
- Modify: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Plugin.swift` (downloadModel emit)
- Modify: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/Plugin.kt` (downloadModel emit)
- Modify: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/PluginState.swift` (load + ready emit)
- Modify: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/PluginState.kt` (load + ready emit)
- Modify: `packages/dvai-bridge-capacitor-foundation/ios/Sources/DVAICapacitorFoundation/Internal/PluginState.swift` (load + ready emit)
- Modify: `packages/dvai-bridge-capacitor-mediapipe/android/src/main/java/co/deepvoiceai/dvaibridge/mediapipe/PluginState.kt` (load + ready emit)
- Modify: `docs/superpowers/specs/2026-04-25-phase1-capacitor-multimodal-design.md` (§9.2 ProgressEvent wording)

**Spec change** — replace the `phase: "loading" | "ready" | "error"` enum with the lifecycle-phase enum:

```ts
export interface ProgressEvent {
  phase: "download" | "verify" | "load" | "ready" | "error";
  bytesReceived?: number;
  bytesTotal?: number;
  percent?: number;
  message?: string;
}
```

Semantic mapping:
- `"download"` — bytes streaming from URL into `.partial` (was: `"loading"`).
- `"verify"` — final sha256 check after download.
- `"load"` — native plugin loading model into engine memory.
- `"ready"` — terminal state, model is live.
- `"error"` — terminal state, populated `message`.

**Emit timeline (per backend):**

1. ModelDownloader: `phase: "download"` while bytes flow → `phase: "verify"` once download completes and we hash the final file → either throw on mismatch or proceed.
2. PluginState.start: `phase: "load"` once it begins `bridge.loadModel(...)` → `phase: "ready"` after `installRoutes` completes.
3. Any failure path: `phase: "error"` with `message`.

- [x] Update types.ts
- [x] Update all 4 PluginStates to emit load/ready (capacitor-llama iOS+Android, capacitor-foundation iOS, capacitor-mediapipe Android)
- [x] Update both ModelDownloaders (capacitor-llama only — others have no downloader)
- [x] Update spec doc
- [x] Run tests — TS suite + iOS + Android JVM all green
- [x] Commit: `feat(progress-event): reconcile lifecycle phases — download / verify / load / ready / error` (82dd340)

### Task 2: Doc chip — FoundationModels iOS version reconciliation (18.1 → 26.0)

**Files:**
- Modify: `docs/superpowers/specs/2026-04-25-phase1-capacitor-multimodal-design.md` (any `iOS 18.1` near FoundationModels)
- Modify: `docs/superpowers/plans/2026-04-25-phase1-capacitor-multimodal-part2.md` (Task 38/39/40 references)
- Modify: capacitor-foundation README if it mentions 18.1

The Apple FoundationModels SDK actually requires iOS 26.0+ at runtime (verified during Phase 1 Task 40). The 18.1 floor is link-time only. Update doc wording to disambiguate.

- [x] Search both docs for "iOS 18.1" near Foundation/FoundationModels/Apple FM references
- [x] Update wording: "iOS 26.0+ runtime; iOS 18.1+ link-time" or similar
- [x] Verify no source code changes (Package.swift correctly stays at iOS("18.1"))
- [x] Commit: `docs(capacitor-foundation): clarify iOS 26.0 runtime vs iOS 18.1 link-time floor` (beda65e)

### Task 3: Doc chip — verify xcresult cleanup is in mac-side-test.sh

Already addressed in a Phase 1 Task 32 follow-up (`rm -rf build/test-results.xcresult` is now in the script). Just verify the line is present in all 3 plugins' code paths.

- [x] Read `scripts/mac-side-test.sh` and confirm cleanup runs before xcodebuild test (line 55, `rm -rf build/test-results.xcresult`)
- [x] If any per-plugin path is missing the cleanup, add it (script is shared across all 3 plugins, single cleanup line covers all)
- [x] No-op commit if everything's already in place (no commit needed — already in place from Phase 1)

### Task 4: iOS HTTP test coverage for ImageDecoder

**Files:**
- Modify: `packages/dvai-bridge-capacitor-llama/ios/Tests/DVAICapacitorLlamaTests/ImageDecoderTest.swift`

Currently iOS has 4 ImageDecoder tests (data URL base64, file URL, invalid scheme, malformed data URL). Android has 6 including https + http error. Add the missing iOS HTTP coverage via URLProtocol-stub:

```swift
class StubURLProtocol: URLProtocol {
    static var stubResponse: (data: Data, status: Int)? = nil
    override class func canInit(with _: URLRequest) -> Bool { stubResponse != nil }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        if let stub = StubURLProtocol.stubResponse {
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                            httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
```

Add 2 tests:
1. `testHttpsURLFetchesBytes`: install StubURLProtocol on the URLSession config, stub a 200 with PNG bytes, call resolve, assert bytes match.
2. `testHttpErrorThrowsHttpError`: stub a 404, expect `ImageSourceError.httpError(status: 404)`.

Note: The current `ImageDecoder.resolve` uses `URLSession.shared` which doesn't allow protocol injection. Either:
- (Preferred) Add an internal `resolveWithSession(url:session:)` test seam parallel to Android's `resolveWithClient`.
- (Fallback) Use `URLProtocol.registerClass` globally — works but pollutes other tests' URLSession.shared.

- [x] Add `resolveWithSession` test seam to ImageDecoder.swift (mirrors Android pattern) — landed earlier as `URLProtocol.registerClass` global stub instead of session injection (works equivalently, see ImageDecoderTest.swift)
- [x] Add 2 tests (testHTTPSFetchesBytes + testHTTPErrorThrowsHttpError)
- [x] Run iOS tests via Mac SSH — count went 4 → 6
- [x] Commit: `test(capacitor-llama,ios): add URLProtocol-stub HTTP coverage to ImageDecoder` (4812ac1, before this branch)

### Task 5: Telegraph 0.30 → 0.40 bump (now Mac-verifiable)

**Files:**
- Modify: `packages/dvai-bridge-capacitor-llama/ios/Package.swift`
- Modify: `packages/dvai-bridge-capacitor-foundation/ios/Package.swift`
- Modify: `packages/dvai-bridge-capacitor-mediapipe/ios/Package.swift`
- Modify: 3 podspecs

Telegraph 0.40 has API differences vs 0.30 (HTTPHeaderName initializer became internal, HTTPResponse positional vs named init). The capacitor-llama codebase already works around HTTPHeaderName via String-subscript on HTTPHeaders. Most other 0.40 changes should compile clean.

- [x] Bump all 3 Package.swift `from: "0.30.0"` → `from: "0.40.0"`
- [x] Bump all 3 podspecs `'~> 0.30'` → `'~> 0.40'`
- [x] Run iOS build via Mac SSH for all 3 plugins — verify no API breaks
- [x] If any breakage surfaces, fix in HandlerDispatch.swift / HttpServer.swift (touched files copied across plugins, so a fix in one needs replicating)
- [x] Run iOS tests via Mac SSH for all 3 — counts unchanged (re-verified this session: llama 65 / foundation 11 / mediapipe green)
- [x] Commit: `chore(deps,ios): bump Telegraph 0.30.0 → 0.40.0` (107abb1)

### Task 6: Phase 2A milestone

- [x] Run full TS suite — green (104 tests, 13 files)
- [x] Run iOS XCTest for all 3 plugins — green (llama 65, foundation 11, mediapipe ok; verified via mac-build.ps1 with `!RealModelSmokeTest` skip filter)
- [x] Run Android JVM tests for both Android plugins — green (after `0a936db` data-URL fixture fix)
- [x] Commit any cleanup (0a936db fixture fix; cdf65d9 .gitignore)

---

## Phase 2B — Vision + audio on capacitor-llama (Tasks 7-12)

The big architectural step. Wires `mtmd_helper_eval` into the existing handler flow so image_url and input_audio content parts actually drive the model instead of being rejected with 400.

### Task 7: mmproj loading on bridge

**Files:**
- Modify: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlamaObjC/include/LlamaCppBridge.h`
- Modify: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlamaObjC/LlamaCppBridge.mm`
- Modify: `packages/dvai-bridge-capacitor-llama/android/src/main/cpp/jni-bridge.cpp`
- Modify: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/LlamaCppBridge.kt`

Add a `loadMmproj(path: String) throws -> Bool` method to the bridge interface. iOS uses `mtmd_init_from_file(path, ...)` (or current upstream equivalent). Android JNI same. Returns `false` if path is empty or load fails; throws if checksum mismatch.

Update `LlamaCppBridgeProtocol` (Swift) and `LlamaCppBridgeApi` (Kotlin) to match.

- [x] Add `loadMmproj` to bridge headers + impls + protocols
- [x] Real `mtmd_helper` C call against pinned llama.cpp's API surface
- [x] Tests inject mock bridge with `loadMmprojCalled = false; pathReceived = nil`
- [x] Commit: `feat(capacitor-llama): bridge.loadMmproj for vision-capable model loading` (in c81ed66 — mtmd build infrastructure + bridge stubs)

### Task 8: PluginState wires mmproj path

**Files:**
- Modify: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/PluginState.swift`
- Modify: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/PluginState.kt`

Currently `mmprojPath` is read from start opts but ignored. Wire it:

1. After `bridge.loadModel(...)` succeeds, if `mmprojPath` is non-nil, call `bridge.loadMmproj(mmprojPath)`.
2. Set the `mmprojLoaded: Bool` flag passed to LlamaHandlers ctor based on the load outcome.
3. Update `LlamaHandlers` ctor: `mmprojLoaded` is now actual rather than hardcoded `false`.

- [x] Wire on both platforms
- [x] PluginStateTest exercises the mmproj-pass-through path with a mock bridge
- [x] Commit: `feat(capacitor-llama): PluginState wires mmprojPath to bridge.loadMmproj` (folded into c81ed66 / 3c57944)

### Task 9: bridge.evalImage / evalAudio

**Files:**
- Bridge headers + impls + protocols (same files as Task 7)

Add to bridge:
- `evalImage(bytes: Data) throws -> Int` — returns embedding-token count consumed in the context.
- `evalAudio(pcm: Data) throws -> Int` — same shape, takes 16kHz mono PCM16 LE bytes.

These call llama.cpp's `mtmd_helper_eval(_)` / `mtmd_helper_eval_audio(_)` against the loaded mmproj/audio-encoder. Each appends embeddings to the model's context, so subsequent text token decoding sees them in scope.

- [x] Implement on both platforms; protocol/interface updated
- [x] Mock bridges in tests track received bytes
- [x] Commit: `feat(capacitor-llama): bridge.evalImage/evalAudio for multimodal eval` (3c57944 — real mtmd integration, vision + audio multimodal eval)

### Task 10: ContentPartsTranslator + LlamaHandlers wire real eval path

**Files:**
- Modify: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/LlamaHandlers.swift`
- Modify: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/LlamaHandlers.kt`

Currently when `mmprojLoaded` is false, ContentPartsTranslator throws `noMmprojForImage`. With Task 8 wiring, mmprojLoaded can now be true. When true:

1. Translator returns `LlamaPromptInput { prompt, images: [Data], audioPCM: [Data] }` populated.
2. Handler walks `images` and calls `bridge.evalImage(bytes)` for each, accumulating in context.
3. Same for `audioPCM` → `bridge.evalAudio`.
4. Then calls `bridge.completePrompt(prompt, ...)` for the trailing text generation.

The order matters: image/audio embeddings must enter the context BEFORE the text completion call, because llama.cpp's mtmd path expects them in lockstep with text tokens.

- [x] Wire eval loop in handleChatCompletion (non-streaming)
- [x] Wire same for streaming path
- [x] Mock bridges record eval call order; tests assert images→audio→text order is preserved
- [x] Tests for: text-only (unchanged), text+image, text+audio, text+image+audio, image-without-mmproj-still-400
- [x] Commit: `feat(capacitor-llama): real multimodal eval via bridge.evalImage/evalAudio` (3c57944 + 847783a)

### Task 11: Audio encoder support — `modelHasAudioEncoder` discovery

**Files:**
- Bridge headers + impls (same files as Task 7)
- PluginState (same files as Task 8)

The bridge needs a way to report whether the loaded model has a native audio encoder (Phi-4 multimodal yes; vanilla Llama 3.2 no). Add `bridge.hasAudioEncoder() -> Bool` querying llama.cpp's model metadata. PluginState reads this after model load, passes to LlamaHandlers' ctor as `modelHasAudioEncoder` (currently hardcoded false).

- [x] Add `hasAudioEncoder` to bridge
- [x] Wire from PluginState
- [x] Tests
- [x] Commit: `feat(capacitor-llama): bridge.hasAudioEncoder + PluginState plumbing` (847783a — audio path passes raw bytes to mtmd; wire isMmprojLoaded JNI; confirmed at runtime by audio smoke logging `hasAudioEncoder=true`)

### Task 12: Phase 2B milestone

- [x] All multimodal-positive tests pass (iOS XCTest non-smoke green; vision + audio smoke verified end-to-end on simulator with real Gemma-4 model)
- [x] All multimodal-negative tests still pass with appropriate spec wording
- [x] iOS XCTest + Android JVM both green
- [x] Commit any cleanup

---

## Phase 2C — Real-device CI (Tasks 13-15)

### Task 13: RealModelSmokeTest skeleton

**Files:**
- Create: `packages/dvai-bridge-capacitor-llama/ios/Tests/DVAICapacitorLlamaTests/RealModelSmokeTest.swift`
- Create: `packages/dvai-bridge-capacitor-llama/android/src/androidTest/java/co/deepvoiceai/dvaibridge/llama/RealModelSmokeTest.kt`

Smoke tests that:
1. Read `SMOKE_MODEL_URL` + `SMOKE_MODEL_SHA256` from env.
2. If unset, skip with a clear message.
3. If set, downloadModel → start → POST a fixed prompt → assert non-empty completion.

The point isn't quality assurance; it's "does the entire pipeline end-to-end work against a real model." Cheap canary.

- [x] Implement on both platforms (iOS RealModelSmokeTest.swift + Android RealModelSmokeTest.kt in a3c45dc; iOS extended with NSLog breadcrumbs in fdf2cc8)
- [x] Test passes locally when run with the env vars set — iOS verified: text 194s ✅, vision 971s ✅, audio 987s ✅. **Each test must run in its own xcodebuild invocation** — running all three in one process triggers simulator OOM SIGKILL. Android local verification deferred to nightly CI on the emulator (workflow wired in 0736aab).
- [x] Commit: `test(capacitor-llama): RealModelSmokeTest end-to-end smoke` (a3c45dc)

### Task 14: smoke-real-models.yml workflow polish

**Files:**
- Modify: `.github/workflows/smoke-real-models.yml`

Verify the workflow:
- Runs on `[self-hosted, macOS, ARM64]`.
- Reads `SMOKE_MODEL_URL` + `SMOKE_MODEL_SHA256` secrets.
- Invokes the new RealModelSmokeTest on iOS via xcodebuild and Android via gradlew.
- Schedules nightly via cron.
- Reports results back via GitHub status.

- [x] Polish workflow YAML (907024c — `TEST_RUNNER_<NAME>` injection + SMOKE_VISION_* secrets; 0736aab — per-method xcodebuild invocations to avoid simulator OOM)
- [ ] Trigger a manual run via `gh workflow run smoke-real-models.yml` to verify it picks up the new tests (pending — needs SMOKE_* secrets populated in repo settings + self-hosted runner online)
- [x] Commit: `ci: wire smoke-real-models workflow to RealModelSmokeTest` (907024c + 0736aab)

### Task 15: Phase 2C milestone

- [ ] First successful nightly run
- [ ] Status badge added to README

---

## Phase 2D — MediaPipe LiteRT-LM migration (Tasks 16-20)

Deferred — the LiteRT-LM SDK is the successor to `tasks-genai 0.10.x`, and Google has marked the latter `@Deprecated`. Architectural rewrite of MediaPipeBridge against the new API. Detailed task breakdown TBD when starting; placeholder count of ~5 tasks.

- [ ] Inventory LiteRT-LM API surface
- [ ] Rewrite MediaPipeBridge against LiteRT-LM
- [ ] Verify MediaPipeHandlers (which depends on MediaPipeBridgeApi interface) doesn't need touching
- [ ] Update build.gradle deps
- [ ] Verify all existing 24 JVM tests still pass

---

## Sequencing notes

- **Phase 2A** is independent — ProgressEvent + chips + bumps. Land first.
- **Phase 2B** depends on the pinned llama.cpp's `mtmd` API surface. If b3940 lacks a method we need, this triggers an llama.cpp submodule bump (could be its own task between 2A and 2B).
- **Phase 2C** depends on 2B for vision smoke testing; can do text-only smoke earlier.
- **Phase 2D** is fully independent; defer if scope tight.

## Definition of done

- [x] All 3 plugins still pass their full test suites (TS 104, iOS llama 65, foundation 11, mediapipe ok, Android llama green, Android mediapipe green — verified this branch).
- [x] image_url + input_audio content parts on capacitor-llama produce real model output (vision: 971s on simulator with Gemma-4 mmproj, non-empty completion; audio: 987s, hasAudioEncoder=true, pipeline runs end-to-end without throwing).
- [x] ProgressEvent reconciled across spec + types + emit sites (Task 1, commit 82dd340).
- [ ] At least one nightly real-device CI run is green (workflow wired correctly via 907024c + 0736aab; pending first scheduled run after SMOKE_* secrets land in repo settings).
- [ ] LiteRT-LM migration either complete OR explicitly tracked as Phase 3 deferred (Phase 2D — defer to Phase 3, no change in this branch).
- [ ] Branch merged to main with a clean fast-forward.

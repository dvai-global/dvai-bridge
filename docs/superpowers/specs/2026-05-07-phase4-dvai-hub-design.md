# Phase 4 — DVAI Hub (household-utility flavor of distributed inference)

**Status:** Draft (2026-05-07) — pre-implementation. Targets v3.1.0.
**Date:** 2026-05-07
**Scope:** A first-party desktop-class inference utility (Windows / macOS / Linux) that runs in "be-a-peer" mode for any dvai-bridge mobile app on the same LAN or paired via rendezvous. Closes the "mobile-only developer" gap that v3.0 left open: a developer who ships only an iOS / Android app, with no desktop counterpart, can now leverage v3-class distributed inference because the user's household can install **DVAI Hub** once and have it act as a generic strong-peer for any number of dvai-bridge apps.

This is not a replacement for v3.0 — it sits on top of the v3.0 substrate. v3.0 ships the *capability* (LAN discovery + rendezvous-mediated pairing + offload protocol). v3.1 ships the *artifact* that exploits that capability for the most common consumer scenario (one strong device per household, several mobile apps that want to use it).

## Sub-phase position

```
3A core extraction ✅ → 3B LiteRT-LM migration ✅ → 3C iOS SDK ✅
                                                  → 3D Android AAR ✅
                                                  → 3E React Native ✅
                                                  → 3F Flutter ✅
                                                  → 3G .NET NuGet ✅
                                                  → 3H Launch polish ✅
v2.4 — examples matrix ✅
v3.0 — distributed inference (LAN + rendezvous) ✅
v3.1 — Phase 4: DVAI Hub ◀️ YOU ARE HERE
v3.2+ — Hub Redis-backed multi-instance · TensorRT-LLM wrapper · QR-pairing convenience layer (parked)
```

---

## 1. Goals

1. **Ship a desktop binary** (Windows / macOS / Linux) called **DVAI Hub** that any user can install once and use as a strong-peer for any dvai-bridge mobile app.
2. **No app developer participation required.** A mobile-only app developer's users can install Hub and pair with the developer's app. The developer ships nothing extra; Hub is brand-neutral and works with any v3-conformant app.
3. **Smart model routing.** Hub parses the app's requested model name (`gemma-4-E2B-q4-instruct`) into structured fields (family / version / size / quant / type) and routes to the best available backend or external engine, with strict substitution rules that don't violate the agent contract.
4. **External-engine bridge** (opt-in). Hub auto-detects local Ollama / LM Studio / vLLM / llamafile installs and uses them as backends when their cached catalog matches the request — getting the user's already-installed engine investments for free.
5. **Multi-tenant isolation.** Hub serves N apps from N developers concurrently. Each pairs separately, each gets its own pairing-key, each sees only its own offload requests in the dashboard.
6. **Tauri shell.** Cross-platform single-file binaries, ~10 MB each, with a small dashboard UI (paired apps, model library, capability metrics, pairing approve/deny prompts).
7. **Developer-fork template.** Same source can be forked by an app developer to ship a custom branded companion app for their own users (Flavor 2 from the design conversation).

## 2. Non-goals

- **Not a model marketplace.** Hub doesn't curate or recommend models. It serves what apps request, period.
- **Not an agent runtime.** Hub doesn't run agent loops, doesn't store chat history, doesn't have a chat UI for end users. It's a server for other apps' agent code.
- **Not a replacement for Ollama / LM Studio / vLLM.** Hub is the OpenAI-HTTP shim + distributed-inference protocol layer; the underlying engines (Ollama, llama.cpp, MLX, ONNX, etc.) remain the right tools for their layer. Hub *bridges* to them.
- **No mobile version of Hub.** The whole point of Hub is to live on the strong device the user owns. Mobile apps consume Hub; they don't run it.
- **No internet-without-rendezvous.** Hub uses the same LAN-mDNS + rendezvous-server paths the v3.0 substrate already provides. We don't introduce new transport mechanisms.
- **No TensorRT-LLM wrapper.** Parked per the conversation in §10. The external-engine bridge covers the "I have NVIDIA + already use TensorRT-LLM" case for power users.

## 3. Surface (deliverables)

### 3.1 The DVAI Hub binary

`hub/` directory at monorepo root, sibling to `rendezvous/`. Self-contained, deployable independently.

```
hub/
├── package.json              # Tauri's package.json (Node side)
├── src-tauri/                # Rust shell
│   ├── Cargo.toml
│   ├── tauri.conf.json
│   └── src/
│       └── main.rs
├── src/                      # Web frontend (React + TypeScript)
│   ├── App.tsx
│   ├── components/
│   ├── hooks/
│   └── api/                  # IPC bridge to Rust → peer-mode core
├── peer-mode/                # Shared "be-a-peer" library (TypeScript)
│   ├── PeerMode.ts           # wraps @dvai-bridge/core
│   ├── ModelParser.ts        # parseModelName(): family/version/size/quant/type
│   ├── EngineBridge.ts       # external-engine probe + adapter interface
│   ├── adapters/
│   │   ├── OllamaAdapter.ts
│   │   ├── LMStudioAdapter.ts
│   │   ├── VLLMAdapter.ts
│   │   ├── LlamaServerAdapter.ts
│   │   └── LlamafileAdapter.ts
│   ├── SubstitutionPolicy.ts
│   └── MultiTenantPairing.ts
├── tests/
│   ├── ModelParser.test.ts
│   ├── EngineBridge.test.ts
│   ├── SubstitutionPolicy.test.ts
│   └── MultiTenantPairing.test.ts
├── README.md                 # one-click install (Homebrew / winget) + first-run flow
├── DEVELOPER-FORK.md         # how to fork into a custom-branded companion (Flavor 2)
└── .github/workflows/
    └── release.yml           # cross-platform binary builds + GitHub Release
```

### 3.2 The first-party binary (Flavor 1)

Cross-platform single-file binaries:
- **Windows**: `dvai-hub-{version}-windows-x64.msi` + `winget` manifest
- **macOS**: `dvai-hub-{version}-macos-arm64.dmg` + Homebrew formula (universal binary on x86_64 too)
- **Linux**: `dvai-hub-{version}-linux-x64.AppImage` + `.deb` + `.rpm`

Distribution paths:
- GitHub Releases (canonical source of binaries).
- Homebrew tap: `deepvoiceai/dvai-hub`.
- winget package: `DeepVoiceAI.DVAIHub`.
- (Future, parked) Snap, Flatpak, AUR.

### 3.3 The developer-fork template (Flavor 2)

`hub/` is itself the template. An app developer who wants a branded companion forks the directory, replaces:
- `hub/src-tauri/tauri.conf.json` (app name, icon, identifier, signing)
- `hub/src/App.tsx` (branding, copy)
- `hub/peer-mode/MultiTenantPairing.ts` (single-tenant default — only their app pairs)

Document the diff in `hub/DEVELOPER-FORK.md` so the fork-and-customize path is explicit.

### 3.4 The dashboard UI

Tray icon + small dashboard window. Tabs:

1. **Status** — running / paused, port, current capacity score, recent offloads.
2. **Paired Apps** — list of paired apps (deviceId + deviceName + last-seen) with revoke buttons.
3. **Models** — installed models (across all backends), download new, delete, set defaults per family.
4. **Engines** — detected external engines (Ollama, LM Studio, etc.) + enable/disable toggle.
5. **Settings** — port range, mDNS service name, rendezvous URL (optional), model cache location, auto-start at login.
6. **Logs** — recent offload requests (model, source app, duration, outcome). 30-day rolling window.

### 3.5 Pairing approval UI

When a new device tries to pair, a system notification fires with the device name + app name (if the app supplied a `userAgent`-style hint in the handshake) + Approve / Deny / Always Allow buttons. The Approve flow walks the user through:

- Confirming the device name matches their phone/tablet.
- Choosing the trust level: this-session, 30-days, always.
- Optionally restricting which models this app can request (e.g. allow Llama 3.2 family but not Llama 4 if the user has model-size concerns).

## 4. Design

### 4.1 Architecture

Hub is a thin Rust/Tauri shell wrapping the existing `@dvai-bridge/core` Node library. The Rust side handles:

- Process supervision (start / stop the embedded Node peer-mode process).
- IPC bridge to the web frontend (Tauri's `invoke` mechanism).
- OS integrations (tray icon, system notifications, auto-start).
- Single-instance lock (only one Hub running at a time).

The Node-side `peer-mode/` library:

- Imports `@dvai-bridge/core` and configures it in "be-a-peer" mode (mDNS advertiser on by default; HTTP server bound to `0.0.0.0` not just `127.0.0.1` so LAN peers can reach it; pairing policy with the host-app callback wired to system notifications).
- Layers on the model parser, external-engine bridge, substitution policy, multi-tenant pairing isolation.

### 4.2 The model parser

`peer-mode/ModelParser.ts` exposes `parseModelName(string) → ModelDescriptor`:

```ts
interface ModelDescriptor {
  family: string;           // e.g. "gemma", "llama", "phi", or "unknown"
  version: string | null;   // e.g. "4", "3.2", or null
  size: string;             // normalized to lowercase + format: "1b" | "2b" | "3b" | "7b" | "70b" | "e2b" | "mini" | "medium" | "unknown"
  quant: string | null;     // canonical: "q2_k" | "q4_0" | "q4_k_m" | "q8_0" | "f16" | "f32" | "4bit" | "8bit" | "int4" | null
  type: string;             // "instruct" | "chat" | "code" | "base" | "vision" | "embed" | "unknown"
  originalString: string;   // verbatim input
}
```

Strategy: regex-based vocabulary lookup. Parser ships an internal alias table:

```ts
const FAMILY_ALIASES = { "gemma": "gemma", "llama": "llama", "phi": "phi", ... };
const SIZE_ALIASES   = { "1b": "1b", "1B": "1b", "1.1B": "1b", "E2B": "e2b", ... };
const QUANT_ALIASES  = { "Q4_K_M": "q4_k_m", "q4f16_1": "q4_k_m_approx", "4bit": "4bit", ... };
const TYPE_ALIASES   = { "instruct": "instruct", "Instruct": "instruct", "it": "instruct", "chat": "chat", ... };
```

When the input doesn't match any vocabulary entry, the parser returns `family: "unknown"` and the substitution policy refuses to substitute. The original string is always preserved so the chosen backend can use it for its own model resolution.

Tested against the canonical naming conventions — at minimum:
- `gemma-4-E2B-q4-instruct` (user's example)
- `Llama-3.2-3B-Instruct-Q4_K_M` (llama.cpp / GGUF)
- `mlx-community/Llama-3.2-3B-Instruct-4bit` (HF MLX)
- `microsoft/Phi-3-mini-4k-instruct-onnx` (HF ONNX)
- `gemma-2-2b-it-q4f16_1-MLC` (MLC)
- `gemma:2b` (Ollama)
- `meta-llama/Llama-3.2-3B-Instruct` (raw HF)
- `bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M` (GGUF tag-style)

### 4.3 The external-engine bridge

`peer-mode/EngineBridge.ts` orchestrates two phases:

**Phase A — HTTP detection** (fast, no shell):

```ts
const engines = [
  { name: "ollama",     probe: "GET http://localhost:11434/api/tags" },
  { name: "lmstudio",   probe: "GET http://localhost:1234/v1/models" },
  { name: "vllm",       probe: "GET http://localhost:8000/v1/models" },
  { name: "llama-server", probe: "GET http://localhost:8080/v1/models" },
];
```

Each adapter (`adapters/OllamaAdapter.ts`, etc.) implements:

```ts
interface EngineAdapter {
  detect(): Promise<boolean>;                  // is this engine running?
  enumerateCachedModels(): Promise<ModelDescriptor[]>;  // full catalog (Phase B)
  serveRequest(descriptor: ModelDescriptor, request: ChatRequest): Promise<Response>;
}
```

**Phase B — full-catalog enumeration** (subprocess, slower):

- **Ollama**: `ollama ls` → parse table → `[{name: "gemma:2b", size: "1.4GB", modified: "..."}]`. Each row mapped through `parseModelName` to produce a `ModelDescriptor`.
- **LM Studio**: `lms ls` (LM Studio CLI 0.3.x+) → similar.
- **vLLM**: no enumeration CLI; the server only knows about the model it was launched with. Adapter limits itself to that one.
- **llama-server**: same as vLLM; single model per process.
- **llamafile**: not a server — it's a single-binary that bundles a model. Adapter scans `~/.llamafile/` (configurable) for `.llamafile` files.

Caching: each adapter caches its enumerated catalog in memory with a TTL (default 5 min). Hub also listens for `fs.watch` on the well-known model dirs so freshly-downloaded models surface within seconds without waiting for the next poll.

Filesystem scanning (for engines without a CLI):

- `~/.cache/llama.cpp/`, `~/.lmstudio/models/`, `~/.ollama/models/blobs/`, `~/Library/Application Support/dvai-bridge/models/`, user-configurable extras.
- Recursive scan for `.gguf`, `.tflite`, `.task`, `.mlpackage`, `.mlx-safetensors` files.
- Each file's name/path mapped through `parseModelName` (best-effort; many filename conventions in the wild).

### 4.4 The substitution policy

`peer-mode/SubstitutionPolicy.ts` codifies the routing rules from the conversation:

```ts
function pickBackend(
  request: ModelDescriptor,
  available: { backend: string; descriptor: ModelDescriptor }[],
  policy: SubstitutionPolicy,
): RoutingDecision {
  // Rule 1: exact match (family + version + size + type + quant) → serve directly
  // Rule 2: exact family + version + size + type, BETTER quant (or unquantized) → serve only if `policy.preferBetterQuant` is true
  // Rule 3: exact family + version + size + type, lower-quality quant → serve (still contract-compliant) + log "quality_degraded" warning to consumer
  // Rule 4: different `type` (chat vs instruct) → REFUSE (return no_capable_device)
  // Rule 5: different `version` → REFUSE
  // Rule 6: different `size` → REFUSE
  // Rule 7: different `family` → REFUSE
}
```

`policy.preferBetterQuant` is `false` by default (locked decision from the conversation). The mobile app opts in via:

- An `X-DVAI-Substitute: prefer-better-quant` request header (per-request opt-in), OR
- A pairing-time `OffloadConfig.allowQuantSubstitution: true` flag the app sets when paring with Hub.

The response payload always includes a new `usedModel` field naming what actually ran:

```json
{
  "id": "...",
  "model": "gemma-4-E2B-q4-instruct",
  "usedModel": "gemma-4-E2B-q8-instruct",
  "choices": [...]
}
```

This keeps the contract honest: the consumer can audit what served their request, and an instrumentation pipeline can flag mismatches.

### 4.5 Multi-tenant pairing isolation

`peer-mode/MultiTenantPairing.ts`:

- Each paired app gets a unique `pairingKey` (the standard v3.0 HMAC handshake; nothing changes at the wire level).
- Hub stores per-app state under `~/Library/Application Support/dvai-hub/` (macOS) / `%LOCALAPPDATA%\dvai-hub\` (Windows) / `~/.local/share/dvai-hub/` (Linux):
  - `pairings.json` — list of paired devices keyed by their `deviceId`.
  - `apps/<app-id>/cache.json` — per-app capability cache (so two apps' probe results don't conflict).
  - `apps/<app-id>/audit.log` — per-app rolling log of offload requests (model, timestamp, outcome).
- The dashboard's "Paired Apps" tab lists each app separately. Revoking one doesn't affect the others.
- The pairing handshake protocol carries an optional `appName` field the source device supplies (host-app's name). Hub displays this in the approval UI: "Allow MyChatApp on iPhone-15-Pro to use this device for AI?"
- An `appId` field disambiguates apps with the same name: it's a hash of (handshake-time secret + app's bundle/package identifier). Apps don't have to do anything special — the source device sends what it knows; Hub stores what it gets.

### 4.6 The peer-mode wrapper

`peer-mode/PeerMode.ts` is the entry point:

```ts
import { DVAI } from "@dvai-bridge/core";
import { ModelParser } from "./ModelParser";
import { EngineBridge } from "./EngineBridge";
import { SubstitutionPolicy } from "./SubstitutionPolicy";
import { MultiTenantPairing } from "./MultiTenantPairing";

class PeerMode {
  constructor(opts: PeerModeOptions) {
    this.dvai = new DVAI({
      backend: "auto",  // resolves per device
      offload: {
        enabled: true,
        discoverLAN: true,
        rendezvousUrl: opts.rendezvousUrl,  // optional, host-supplied
        onPairingRequest: this.handlePairingRequest.bind(this),
      },
    });
    this.modelParser = new ModelParser();
    this.engineBridge = new EngineBridge({ enabled: opts.externalEnginesEnabled });
    this.substitutionPolicy = new SubstitutionPolicy({ preferBetterQuant: false });
    this.multiTenant = new MultiTenantPairing();
  }

  async start(): Promise<void> { ... }
  async stop(): Promise<void> { ... }

  // Wires the app's chat-completion request through the parser → engine bridge → substitution policy → backend dispatch.
  async handleRequest(req: ChatRequest, sourceApp: AppDescriptor): Promise<Response> {
    const descriptor = this.modelParser.parse(req.body.model);
    const available = await this.engineBridge.enumerateAvailable(descriptor);
    const decision = this.substitutionPolicy.pick(descriptor, available);
    if (decision.kind === "refuse") return this.noCapableDeviceResponse(decision);
    return decision.backend.serve(req, descriptor);
  }
}
```

### 4.7 Distribution

Three OS-native packagings, all built from the same Tauri source via cross-compilation in CI:

- **GitHub Releases**: canonical. Auto-built by `.github/workflows/release.yml` on `v3.1.*` tags. Artifacts: `.msi` (Windows), `.dmg` (macOS), `.AppImage` + `.deb` + `.rpm` (Linux).
- **Homebrew**: a separate formula repo (`Westenets/homebrew-dvai-hub`) with a `dvai-hub.rb` formula that downloads from GitHub Releases. Updated by an `update-homebrew-formula.yml` workflow when a new tag fires.
- **winget**: a manifest in `microsoft/winget-pkgs` PR'd by a similar `update-winget.yml` workflow. Approved by Microsoft's bot if the manifest passes their automated checks.

The **first-party Hub** ships with the team's GitHub Releases as the source. The **developer-fork template** documents how to set up the same CI for a forked repo (the workflows themselves are template-able).

### 4.8 First-run flow

User installs Hub. Tray icon appears. Single-instance lock starts the Hub HTTP server. mDNS advertiser starts.

On first launch, dashboard window opens once with a 3-step setup:
1. **Welcome.** Brief explanation: "Hub lets your phone offload AI inference to this device. No app developer involvement needed."
2. **Engines.** Detected external engines (Ollama if installed, etc.) listed with checkboxes. Default: all unchecked (opt-in). User toggles each on if they want Hub to route requests to it.
3. **Pairing.** "When an app on your phone tries to pair with this device, you'll see a notification. Approve apps you trust." (This is just informational — no action required.)

After setup, the window closes; tray icon stays. User can re-open the dashboard from the tray menu.

## 5. Open questions / decisions (locked from conversation)

### Q1: Substitution default — aggressive or strict?

**Decision:** strict. `policy.preferBetterQuant` defaults to `false`. App opts in per-request via `X-DVAI-Substitute: prefer-better-quant` header or per-pairing via `OffloadConfig.allowQuantSubstitution`.

### Q2: External-engine bridge — opt-in or opt-out?

**Decision:** opt-in. First-run wizard's step 2 is the toggle. Default: off. Apps that need maximum compatibility get the embedded backends; power users with Ollama already running flip the toggle once.

### Q3: Tauri vs Electron?

**Decision:** Tauri. ~10 MB binaries vs Electron's ~80 MB; less RAM at idle; native OS integrations (tray, notifications, single-instance lock) are first-class in Tauri 2.x. Trade-off: Rust toolchain in our build matrix. Acceptable.

### Q4: Mobile version of Hub?

**Decision:** No. Hub is desktop-only. Mobile devices are offload *sources*, not targets. (Phones can't reliably accept inbound HTTP across networks anyway.)

### Q5: How does the developer-fork template diverge from Flavor 1?

**Decision:** minimal divergence. Same source; the developer changes branding (icon + app name + URL scheme) + restricts pairings to their own app via `MultiTenantPairing.allowedAppIds = [theirAppId]`. The fork remains a thin layer.

### Q6: TensorRT-LLM wrapper?

**Decision:** parked for v3.2+. The external-engine bridge already covers "I have TensorRT-LLM running locally" via a future TensorRT-LLM adapter (the architecture is open to it). Trigger to revisit: a paying customer with a fleet of NVIDIA workstations + benchmarks showing >2× lift over llama.cpp CUDA on their workload. Until then, llama.cpp CUDA is the "good default" for NVIDIA.

### Q7: Brand name?

**Decision:** DVAI Hub.

### Q8: Distribution to App Stores?

**Decision:** No. GitHub Releases + Homebrew + winget cover ~95% of the desktop developer audience. App Stores add review-cycle overhead and don't fit the "background utility" UX. Revisit when the user demand is documented.

### Q9: License?

**Decision:** same dual-license as the parent dvai-bridge library — free for personal use, commercial license required for production deployments. The DVAI Hub binary itself is free for personal use; commercial Hub deployments (e.g. an enterprise rolling Hub out to N corporate Macs) require the commercial license.

### Q10: Should Hub auto-update?

**Decision:** opt-in via the first-run wizard (extra step 4 we'll add). Default off — desktop tools that auto-update without permission burn user trust. User can enable it with a checkbox.

### Q11: Multi-user (household) support — how does Hub handle multiple users on the same Mac?

**Decision:** per-user install. Hub installs to the user's home directory; each macOS / Windows user account gets its own Hub instance with its own pairings. (Same mac, different users, different Hub state.) Document this clearly; defer multi-user-shared-Hub to v3.3+ if there's demand.

## 6. Risks

- **R1: Rust toolchain in build CI.** Mitigation: GitHub Actions Rust support is excellent; `cargo` caches well. Trade vs. Electron's Node-only build was deliberate.
- **R2: External-engine adapters churn upstream** (Ollama / LM Studio update their CLI / API). Mitigation: each adapter is a small file; semver-compatible upstream changes are silent; breaking changes manifest as adapter test failures, addressed via a patch release.
- **R3: Model parser misclassifies a novel naming convention.** Mitigation: parser falls back to `family: "unknown"`; substitution refuses; consumer gets exact-match-or-no-capable-device. Failure mode is *strictness*, not silent wrong-routing.
- **R4: Multi-tenant pairing leak.** Mitigation: per-app cache directories enforce filesystem isolation; per-app HMAC keys prevent cross-app spoofing; audit log lets the user verify what served what.
- **R5: Tauri's WebView security model differs from Electron's.** Mitigation: Hub's frontend is fully local; no remote content. Tauri's CSP-by-default is stricter than Electron, which is *good* here.
- **R6: GitHub Releases binary signing on macOS / Windows.** Mitigation: Tauri 2 supports macOS notarization + Windows code-signing in CI. Costs: Apple Developer ID ($99/year) + a DigiCert / SSL.com cert ($200-500/year). Worth it; users won't run unsigned utilities. Document the cost in `PUBLISHING.md`.
- **R7: Update mechanism for the Homebrew formula + winget manifest.** Mitigation: GitHub Actions workflows automate both. Initial PR to `microsoft/winget-pkgs` is manual; subsequent updates auto.

## 7. Phased delivery within Phase 4

- **v3.1.0-rc1** (~2 weeks of work with parallel agents): peer-mode wrapper + model parser + multi-tenant pairing + Tauri shell + first-run wizard + dashboard UI (status + paired apps + models + settings tabs). External-engine bridge wired but adapters minimal (Ollama only).
- **v3.1.0** (~1 more week): more engine adapters (LM Studio, vLLM, llama-server, llamafile) + filesystem scanner + auto-update opt-in + cross-platform CI for binary releases + Homebrew formula + winget manifest. Logs tab.
- **v3.1.x patches** (ongoing): bug fixes from real-world use; new engine adapters as users request them.
- **v3.2.0** (parked): persistent rendezvous-pairing across reconnects; TensorRT-LLM wrapper; Redis-backed rendezvous-server scaling.

## 8. Effort estimate

- **Spec + plan**: done with this document + `docs/superpowers/plans/2026-05-07-phase4-dvai-hub.md`.
- **Tauri shell + IPC + tray + single-instance**: ~12 hours.
- **Peer-mode wrapper around `@dvai-bridge/core`**: ~4 hours.
- **Model parser + tests against the canonical naming-convention corpus**: ~6 hours.
- **External-engine bridge (Ollama + LM Studio + vLLM + llama-server + llamafile adapters)**: ~12 hours total.
- **Substitution policy + tests**: ~4 hours.
- **Multi-tenant pairing isolation**: ~6 hours.
- **Dashboard UI (5 tabs + first-run wizard + pairing approval)**: ~16 hours.
- **Cross-platform CI (Windows / macOS / Linux binaries; signing; notarization)**: ~10 hours.
- **Homebrew formula + winget manifest + update workflows**: ~6 hours.
- **Developer-fork template + DEVELOPER-FORK.md**: ~3 hours.
- **Public docs (`docs/guide/dvai-hub.md` + migration `v3.0-to-v3.1.md`)**: ~4 hours.
- **End-to-end testing across 2 mobile + 1 Mac + 1 Windows**: ~8 hours.

**Total wall-clock: ~91 hours.** With parallel agents: ~25-30 hours real-time. Roughly 3 weeks part-time.

## 9. Acceptance criteria for v3.1.0

- A user installs Hub via the GitHub Releases binary, the Homebrew formula, or the winget package — first-run wizard appears, completes, tray icon stays.
- A v3.0-conformant mobile app on the same LAN discovers Hub via mDNS, sends a chat-completion request — Hub fires the pairing-approval notification, user approves, request runs, response streams back.
- The same mobile app pairs with TWO different Hubs running on two different machines on the same LAN — Hub-side capability scores let the app pick the strongest one transparently.
- Two unrelated mobile apps on the same phone pair with the same Hub — Hub keeps their state isolated; revoking one doesn't affect the other.
- App requests `gemma-4-E2B-q4-instruct`; Hub has `gemma-4-E2B-q8-instruct` cached; substitution policy refuses (because `preferBetterQuant: false` by default); response is `no_capable_device`. Then app sends the same request with `X-DVAI-Substitute: prefer-better-quant` — Hub serves the q8 model and the response carries `usedModel: gemma-4-E2B-q8-instruct`.
- App requests a chat-typed model; Hub has only an instruct-typed model — Hub refuses with `no_capable_device` regardless of the substitution flag.
- Hub auto-detects Ollama running on `localhost:11434`; user enables it in the Engines tab; Hub successfully routes a Llama-3.2-3B request to Ollama because Ollama has the model cached.
- Tag `v3.1.0` triggers GitHub Actions; binaries land on the Releases page; Homebrew + winget update workflows fire; user can run `brew install deepvoiceai/dvai-hub` and `winget install DeepVoiceAI.DVAIHub`.
- Public docs (`docs/guide/dvai-hub.md`, `docs/migration/v3.0-to-v3.1.md`) ship; `RESEARCH.md` gets a §12 addendum on the Hub design.

## 10. Future / parked items (revisit triggers documented)

- **TensorRT-LLM wrapper.** Trigger: a paying customer with NVIDIA workstation fleet + ≥2× benchmark lift over llama.cpp CUDA on their workload. Until then, the external-engine bridge covers locally-installed TensorRT-LLM via the standard adapter pattern.
- **vLLM wrapped backend.** Trigger: same as TensorRT-LLM, plus willingness to take on Python toolchain in our build matrix. The external-engine bridge already covers locally-installed vLLM.
- **Multi-instance horizontal scaling for the rendezvous server.** Trigger: a single deployer with >10k concurrent rendezvous sessions. Implementation: Redis-backed session store; sticky-LB-not-required.
- **Hub mobile version.** Trigger: a use case where mobile-as-target is genuinely valuable (currently we don't see one — phones aren't where the strong silicon lives).
- **App Store / Mac App Store / Microsoft Store distribution.** Trigger: an enterprise asks for it (corporate IT often requires App Store apps). Cost: review-cycle overhead.
- **Multi-user shared Hub** (one Hub instance serving multiple OS user accounts on the same machine). Trigger: explicit user demand. Implementation: system-wide install path + per-user pairing buckets.
- **QR-pairing convenience layer for Hub** (one-click "show QR on Hub, scan with phone"). Trigger: post-v3.1 once we see how many users actually need it vs LAN-only flow.

---

## 11. Plan-document outline

The plan (`docs/superpowers/plans/2026-05-07-phase4-dvai-hub.md`) decomposes this spec into:

1. Pre-flight: workspace ready, Tauri 2.x toolchain installed, GitHub Releases workflow scaffolding.
2. Peer-mode wrapper around `@dvai-bridge/core` with offload-target configuration.
3. Model parser (most foundational; everything below depends on it).
4. External-engine bridge (Ollama adapter first; others incrementally).
5. Substitution policy.
6. Multi-tenant pairing isolation.
7. Tauri shell scaffolding (Rust side + Node side IPC).
8. Dashboard UI (5 tabs + first-run wizard + pairing approval modal).
9. Tray icon + system notifications.
10. Cross-platform CI (Windows MSI + macOS DMG + Linux AppImage/deb/rpm) with signing.
11. Homebrew formula + winget manifest + update workflows.
12. Developer-fork template + `DEVELOPER-FORK.md`.
13. Public docs (`docs/guide/dvai-hub.md`, `docs/migration/v3.0-to-v3.1.md`, `RESEARCH.md` §12 addendum).
14. End-to-end 2-mobile + 1-Mac + 1-Windows verification.
15. v3.1.0 release: bump root `package.json` 3.0.0 → 3.1.0, sync, CHANGELOG `[3.1.0]`, commit + tag + push, GH Releases trigger.

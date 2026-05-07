# Phase 4 Implementation Plan — DVAI Hub (v3.1.0)

**Spec:** [2026-05-07-phase4-dvai-hub-design.md](../specs/2026-05-07-phase4-dvai-hub-design.md)
**Date:** 2026-05-07
**Target tag:** v3.1.0 (with v3.1.0-rc1 along the way for the core scaffolding).
**Branch:** dedicated `phase4/dvai-hub` (long-lived; merges to main when v3.1.0 ships).

---

## Task ordering

```
0. Pre-flight (Tauri toolchain · GitHub Actions scaffolding · directory structure)
   ↓
1. Peer-mode wrapper around @dvai-bridge/core
   ↓
2. Model parser + canonical-naming-convention test corpus
   ↓
3. Substitution policy (depends on model parser)
   ↓
4. External-engine bridge framework + Ollama adapter (most-used first)
   ↓
5. Multi-tenant pairing isolation
   ↓
6. Tauri shell — Rust side + Node-side IPC
   ↓                                         (TAG: v3.1.0-rc1 = headless Hub)
7. Dashboard UI:
     7a. Status tab + first-run wizard
     7b. Paired Apps tab + revoke flow
     7c. Models tab + manual model download
     7d. Engines tab + opt-in toggles
     7e. Settings tab + pairing approval modal
     7f. Logs tab (last; v3.1.0 final goal)
   ↓
8. Tray icon + system notifications + single-instance lock + auto-start hook
   ↓
9. Additional engine adapters (LM Studio, vLLM, llama-server, llamafile)
   ↓
10. Cross-platform CI (Windows MSI · macOS DMG · Linux AppImage/deb/rpm)
    + macOS notarization + Windows code-signing
   ↓
11. Homebrew formula + winget manifest + update workflows
   ↓
12. Developer-fork template + DEVELOPER-FORK.md
   ↓
13. Public docs:
      - docs/guide/dvai-hub.md (user-facing install + pair guide)
      - docs/guide/dvai-hub-developer-fork.md (Flavor 2 walkthrough)
      - docs/migration/v3.0-to-v3.1.md
      - RESEARCH.md §12 addendum on the Hub architecture
   ↓
14. End-to-end testing: 2 mobile + 1 Mac + 1 Windows verification
   ↓
15. v3.1.0 release: bump root package.json, sync versions, CHANGELOG [3.1.0],
    commit + tag + push, GH Releases workflow fires.
```

---

## Task 0 — Pre-flight (synchronous)

1. Verify Tauri 2.x toolchain installs cleanly on Windows (`pnpm dlx create-tauri-app --beta`) and Mac (via `ssh mac`).
2. Verify cross-compilation targets (`rustup target add x86_64-pc-windows-msvc x86_64-apple-darwin aarch64-apple-darwin x86_64-unknown-linux-gnu`).
3. Verify Apple Developer ID + Windows code-signing cert availability (or document the cost in `PUBLISHING.md` if not yet acquired).
4. Create branch `phase4/dvai-hub` from `main` at `v3.0.0` tag.
5. Create `hub/` directory at monorepo root; not a pnpm workspace member (per the spec — keep it self-contained, like `rendezvous/`).

---

## Task 1 — Peer-mode wrapper around `@dvai-bridge/core`

**Where:** `hub/peer-mode/PeerMode.ts` (Node-side, imported by both the Tauri shell and the developer-fork template).

```ts
import { DVAI } from "@dvai-bridge/core";
import { ModelParser } from "./ModelParser";
import { EngineBridge } from "./EngineBridge";
import { SubstitutionPolicy } from "./SubstitutionPolicy";
import { MultiTenantPairing } from "./MultiTenantPairing";

export interface PeerModeOptions {
  rendezvousUrl?: string;
  externalEnginesEnabled: boolean;
  port?: number;
  bindHost?: string;  // default: 0.0.0.0 for LAN reachability
  multiTenant?: { allowedAppIds?: string[] };  // for Flavor 2 fork: restrict to one app
  onPairingRequest: (request: PairingRequest) => Promise<boolean>;
  onOffloadServed: (audit: OffloadAudit) => void;
}

export class PeerMode {
  constructor(opts: PeerModeOptions);
  async start(): Promise<{ port: number; baseUrl: string }>;
  async stop(): Promise<void>;
  // Status surface for the dashboard
  getActivePairings(): Pairing[];
  getCachedModels(): ModelDescriptor[];
  getDetectedEngines(): EngineSummary[];
  getRecentAudits(limit?: number): OffloadAudit[];
}
```

Verifies that the existing `@dvai-bridge/core` v3.0 surface is sufficient (it should be — Hub uses the v3 distributed-inference plane in its target-side mode).

Tests under `hub/tests/PeerMode.test.ts`: start/stop, pairing-approval call-through, mock chat-completion routing.

---

## Task 2 — Model parser

**Where:** `hub/peer-mode/ModelParser.ts` + `hub/tests/ModelParser.test.ts`.

### Algorithm

1. Strip namespace prefix (org slash): `mlx-community/Llama-3.2-3B-Instruct-4bit` → `Llama-3.2-3B-Instruct-4bit`.
2. Tokenize on hyphens, underscores, dots, slashes, colons.
3. Match each token against vocabulary tables:
   - `FAMILY_ALIASES` — `gemma`, `llama`, `phi`, `qwen`, `mistral`, `deepseek`, `yi`, `tinyllama`, `falcon`, etc.
   - `VERSION_PATTERN` — `(\d+(\.\d+)?)` after a family token.
   - `SIZE_ALIASES` — `1b`, `1B`, `1.1B`, `2B`, `3B`, `7B`, `13B`, `34B`, `70B`, `E2B`, `mini`, `medium`, `tiny`.
   - `QUANT_ALIASES` — `Q4_K_M`, `q4_k_m`, `Q8_0`, `q4f16_1`, `4bit`, `int4`, `8bit`, `int8`, `fp16`, `f16`, `f32`, etc.
   - `TYPE_ALIASES` — `instruct`, `Instruct`, `it`, `chat`, `Chat`, `code`, `Code`, `base`, `vision`, `embed`, `embedding`.
4. Unrecognized tokens are warnings (logged at debug level), not errors. The parser still returns a `ModelDescriptor`; unrecognized fields default to `null`/`"unknown"`.

### Test corpus (canonical naming conventions)

```ts
const CORPUS: Array<{ input: string; expected: ModelDescriptor }> = [
  { input: "gemma-4-E2B-q4-instruct",
    expected: { family: "gemma", version: "4", size: "e2b", quant: "q4", type: "instruct", originalString: "gemma-4-E2B-q4-instruct" } },
  { input: "Llama-3.2-3B-Instruct-Q4_K_M",
    expected: { family: "llama", version: "3.2", size: "3b", quant: "q4_k_m", type: "instruct", ... } },
  { input: "mlx-community/Llama-3.2-3B-Instruct-4bit",
    expected: { family: "llama", version: "3.2", size: "3b", quant: "4bit", type: "instruct", ... } },
  { input: "microsoft/Phi-3-mini-4k-instruct-onnx",
    expected: { family: "phi", version: "3", size: "mini", quant: null, type: "instruct", ... } },
  { input: "gemma-2-2b-it-q4f16_1-MLC",
    expected: { family: "gemma", version: "2", size: "2b", quant: "q4f16_1", type: "instruct", ... } },  // "it" → instruct alias
  { input: "gemma:2b",
    expected: { family: "gemma", version: null, size: "2b", quant: null, type: "unknown", ... } },  // Ollama tag-style; type unknown
  { input: "meta-llama/Llama-3.2-3B-Instruct",
    expected: { family: "llama", version: "3.2", size: "3b", quant: null, type: "instruct", ... } },
  { input: "bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M",
    expected: { family: "llama", version: "3.2", size: "1b", quant: "q4_k_m", type: "instruct", ... } },
  { input: "complete-garbage-string",
    expected: { family: "unknown", version: null, size: "unknown", quant: null, type: "unknown", originalString: "complete-garbage-string" } },
];
```

Tests assert: each entry parses to its expected descriptor. Round-trip property: `parseModelName(originalString).originalString === originalString`.

---

## Task 3 — Substitution policy

**Where:** `hub/peer-mode/SubstitutionPolicy.ts` + `hub/tests/SubstitutionPolicy.test.ts`.

```ts
export interface SubstitutionPolicyOptions {
  preferBetterQuant: boolean;  // default false
}

export type RoutingDecision =
  | { kind: "exact"; backend: BackendDescriptor }
  | { kind: "substituted"; backend: BackendDescriptor; replaced: { from: ModelDescriptor; to: ModelDescriptor }; reason: string }
  | { kind: "refuse"; reason: string };

export class SubstitutionPolicy {
  constructor(opts: SubstitutionPolicyOptions);
  pick(request: ModelDescriptor, available: BackendDescriptor[]): RoutingDecision;
}
```

### Rules (in priority order, returning first match)

1. **Exact match**: any `available[i]` where all fields equal `request` → `{ kind: "exact" }`.
2. **Better quant** (only if `preferBetterQuant: true`): same family + version + size + type, available's quant is "better" per the QUANT_ORDER lookup → `{ kind: "substituted", reason: "better_quant" }`.
3. **Lower-quality quant** (only if `preferBetterQuant: true`): same family + version + size + type, available's quant is "worse" → `{ kind: "substituted", reason: "lower_quant" }` with audit log warning.
4. **Type mismatch**: never substitute — `{ kind: "refuse", reason: "type_mismatch" }`.
5. **Version / size / family mismatch**: never substitute — `{ kind: "refuse", reason: <field>_mismatch }`.

`QUANT_ORDER` = `f32 > f16 > q8_0 > q6_K > q5_K_M > q4_K_M > q4_0 > q3_K > q2_K`. `null` (unquantized) is treated as `f16` for ordering.

Tests:
- 5+ exact-match cases.
- 5+ better-quant substitution cases (with `preferBetterQuant: true` and `preferBetterQuant: false`).
- 5+ refuse cases (type mismatch, version mismatch, etc.).
- Audit-log warning fires on lower-quant substitution.

---

## Task 4 — External-engine bridge framework + Ollama adapter

**Where:** `hub/peer-mode/EngineBridge.ts`, `hub/peer-mode/adapters/OllamaAdapter.ts`, `hub/tests/EngineBridge.test.ts`.

### Framework (`EngineBridge.ts`)

```ts
export interface EngineAdapter {
  readonly name: string;
  detect(): Promise<boolean>;                         // is this engine running?
  enumerateCachedModels(): Promise<ModelDescriptor[]>;  // full catalog
  serveRequest(descriptor: ModelDescriptor, request: ChatRequest): Promise<ChatResponse | StreamResponse>;
  close(): Promise<void>;
}

export interface EngineBridgeOptions {
  enabled: boolean;
  enabledAdapters: string[];  // names of adapters to use
  cacheTtlMs: number;         // default 5 * 60 * 1000
}

export class EngineBridge {
  constructor(opts: EngineBridgeOptions);
  async start(): Promise<void>;          // detect + enumerate all enabled adapters
  async stop(): Promise<void>;
  detected(): EngineSummary[];
  enumerateAvailable(descriptor: ModelDescriptor): Promise<BackendDescriptor[]>;  // matched per request
  invalidateCache(adapterName: string): Promise<void>;
}
```

### Ollama adapter (`adapters/OllamaAdapter.ts`)

- `detect()`: HTTP `GET http://localhost:11434/api/tags` with 1-second timeout.
- `enumerateCachedModels()`: spawn `ollama ls` via `child_process.execFile`, parse the table output, map each row through `parseModelName`. Cache the result with TTL.
- `serveRequest()`: forward the OpenAI-shape request to `POST http://localhost:11434/v1/chat/completions` (Ollama's OpenAI-compat surface). Stream SSE through verbatim.

Tests: mock the HTTP detection; mock the subprocess output; assert the parsed catalog matches expectations; assert `serveRequest` correctly proxies a request.

---

## Task 5 — Multi-tenant pairing isolation

**Where:** `hub/peer-mode/MultiTenantPairing.ts` + `hub/tests/MultiTenantPairing.test.ts`.

Extends the v3.0 `PairingPolicy` from `@dvai-bridge/core` with per-app state isolation:

```ts
export interface MultiTenantPairingOptions {
  storeDir: string;             // ~/Library/Application Support/dvai-hub
  allowedAppIds?: string[];     // for Flavor 2 fork: empty = allow all
  onPairingRequest: (request: PairingRequest) => Promise<boolean>;
}

export class MultiTenantPairing {
  // Stores per-app pairings under {storeDir}/apps/{appId}/pairings.json.
  // Per-app capability cache under {storeDir}/apps/{appId}/cache.json.
  // Per-app audit log under {storeDir}/apps/{appId}/audit.log (rolling, 30-day window).

  async approveOrFetch(request: PairingRequest): Promise<Pairing>;
  async revoke(deviceId: string, appId: string): Promise<void>;
  async revokeAll(appId: string): Promise<void>;
  listPairings(): Promise<Pairing[]>;  // across all apps; UI groups by app
  getAppAudit(appId: string, limit?: number): Promise<OffloadAudit[]>;
}
```

Tests: two apps pair concurrently → independent pairing keys; revoking one doesn't affect the other; audit log is per-app; `allowedAppIds` filter rejects non-listed apps.

---

## Task 6 — Tauri shell

**Where:** `hub/src-tauri/` (Rust) + `hub/src/` (web frontend bridge).

### Rust side

`src-tauri/Cargo.toml`:

```toml
[package]
name = "dvai-hub"
version = "3.1.0"

[dependencies]
tauri = "2"
tauri-plugin-single-instance = "2"
tauri-plugin-system-tray = "2"
tauri-plugin-notification = "2"
tauri-plugin-autostart = "2"
serde = { version = "1", features = ["derive"] }
tokio = { version = "1", features = ["full"] }
```

`src-tauri/src/main.rs`:
- Single-instance lock — second launch passes args to the running instance.
- Spawn Node-side peer-mode process as a child; pipe its stdout/stderr to a log file.
- Tauri commands (IPC entry points): `start_peer_mode`, `stop_peer_mode`, `get_status`, `get_pairings`, `revoke_pairing`, `get_engines`, `enable_engine`, `disable_engine`.
- Tray icon with menu: Open Dashboard / Pause / Quit.
- System notifications via `tauri-plugin-notification` for pairing-approval prompts.

### Frontend bridge (`hub/src/api/`)

```ts
import { invoke } from "@tauri-apps/api/core";

export const api = {
  startPeerMode: () => invoke<{port: number; baseUrl: string}>("start_peer_mode"),
  getStatus: () => invoke<HubStatus>("get_status"),
  getPairings: () => invoke<Pairing[]>("get_pairings"),
  revokePairing: (deviceId: string, appId: string) => invoke("revoke_pairing", { deviceId, appId }),
  // ... etc
};
```

**Gate after Task 6: tag `v3.1.0-rc1`** — headless Hub running peer-mode + IPC + tray icon, but no dashboard UI yet.

---

## Task 7 — Dashboard UI

**Where:** `hub/src/components/`.

Each tab (7a–7f) is a separate React component. Built with shadcn-style primitives + Tailwind. Accessibility-first (keyboard navigation; ARIA labels; high-contrast theme support).

### 7a — Status tab + first-run wizard

- Status tab: badge (running/paused), port + baseUrl, current capability score, recent-offload count.
- First-run wizard: 3-step modal (Welcome → Engines opt-in → Pairing info).

### 7b — Paired Apps

- List of (deviceId, deviceName, appName, lastSeenAt) with a Revoke button per row.
- Group by appName when multiple devices have paired the same app.

### 7c — Models

- List of cached models across all backends.
- Manual download via "Add Model" → asks family/size/type → resolves to a concrete artefact via the existing model registry.
- Delete with confirmation.

### 7d — Engines

- Detected external engines listed (Ollama, LM Studio, etc.) with on/off toggle.
- Engine status: detected / not detected; cached-model count; last-enumerated timestamp.

### 7e — Settings

- Port range (`httpBasePort` / `httpMaxPortAttempts`).
- mDNS service name (advanced).
- Rendezvous URL (optional, for internet path).
- Model cache location (default per-OS).
- Auto-start at login (toggle).

Plus the **Pairing approval modal** — fires when a new device tries to pair. Modal shows: peer device name + app name + Approve / Deny / Always Allow buttons + checkbox for trust duration (this-session / 30-days / always).

### 7f — Logs

- Recent offload requests in a virtualized list: timestamp + appName + model + duration + outcome.
- 30-day rolling window. Per-app audit log read via `getAppAudit()`.
- Export to JSON button.

**Gate after Task 7: dashboard fully functional.**

---

## Task 8 — Tray icon + notifications + single-instance lock + auto-start

Already partially in Task 6. Polish:

- Tray icon: macOS template image + Windows ICO + Linux PNG.
- Notification fallback when system notifications are denied — open the dashboard window with the pairing modal.
- Auto-start hook: macOS Login Items, Windows Run-key, Linux `systemd --user`.

Tests: pairing approval flow on each OS; tray menu actions; auto-start install/uninstall.

---

## Task 9 — Additional engine adapters

For each: detect + enumerate + serveRequest, in `hub/peer-mode/adapters/`.

- **LMStudioAdapter** (HTTP `localhost:1234`; subprocess `lms ls`).
- **VLLMAdapter** (HTTP `localhost:8000`; no enumeration; single-model server).
- **LlamaServerAdapter** (HTTP `localhost:8080`; same).
- **LlamafileAdapter** (no HTTP probe; filesystem scan of `~/.llamafile/` for `*.llamafile` binaries).

Each adapter: a separate file + tests. Adding a new adapter shouldn't require changes to `EngineBridge.ts`.

---

## Task 10 — Cross-platform CI for binary releases

**Where:** `.github/workflows/dvai-hub-release.yml`.

Trigger: push tag matching `v3.1.*`.

Jobs:
- `build-windows`: runs on `windows-latest`, builds `.msi`, signs with the Windows code-signing cert.
- `build-macos`: runs on `macos-latest`, builds universal `.dmg` for x86_64 + arm64, notarizes via Apple Developer ID.
- `build-linux`: runs on `ubuntu-latest`, builds `.AppImage`, `.deb`, `.rpm`.
- `release`: collects artefacts, creates a GitHub Release with the version tag, attaches all binaries.

Documents secrets needed in `RENDEZVOUS-REFERRALS.md`-style sister file `HUB-SIGNING-CERTS.md` (gitignored): `APPLE_SIGNING_IDENTITY`, `APPLE_CERT_BASE64`, `APPLE_CERT_PASSWORD`, `APPLE_NOTARIZATION_USERNAME`, `APPLE_NOTARIZATION_PASSWORD`, `WIN_SIGNING_CERT_BASE64`, `WIN_SIGNING_CERT_PASSWORD`.

---

## Task 11 — Homebrew formula + winget manifest + update workflows

**Homebrew:**
- New repo `Westenets/homebrew-dvai-hub` with `Formula/dvai-hub.rb`.
- Workflow `update-homebrew-formula.yml` runs on `v3.1.*` tags; opens a PR to the formula repo with the new version + sha256.

**winget:**
- Manifest under `manifests/d/DeepVoiceAI/DVAIHub/` in `microsoft/winget-pkgs`.
- Workflow `update-winget-manifest.yml` runs on `v3.1.*` tags; uses the `wingetcreate` tool to update the manifest + open a PR.

Both PRs are auto-merged on success of the respective project's CI.

---

## Task 12 — Developer-fork template

**Where:** `hub/DEVELOPER-FORK.md`.

Step-by-step guide for an app developer who wants a branded companion:

1. Fork the `hub/` directory into their own repo.
2. Replace `src-tauri/tauri.conf.json` (app identifier + bundle ID + icon).
3. Replace `src/App.tsx` branding (name + colors + welcome copy).
4. Set `multiTenant: { allowedAppIds: ["their-app-bundle-id"] }` in `hub/src-tauri/src/main.rs`.
5. Set up their own GitHub Releases CI (template provided).
6. Optional: distribute via their own Homebrew tap + winget package.

Document the upstream-merge story: when DVAI Hub gets a new version, forks pull from upstream and rebase their branding on top.

---

## Task 13 — Public docs

- **`docs/guide/dvai-hub.md`** (new, user-facing): what is DVAI Hub, why install it, install commands per OS, first-run flow, pairing flow, troubleshooting.
- **`docs/guide/dvai-hub-developer-fork.md`** (new, app-developer-facing): how to fork Hub for a branded companion. Cross-references `hub/DEVELOPER-FORK.md`.
- **`docs/migration/v3.0-to-v3.1.md`** (new): backwards-compatible; only new addition is the Hub utility. Mostly reads "no migration needed; install Hub if you want."
- **`RESEARCH.md` §12 addendum** (new section): "DVAI Hub: Generic Strong-Peer Pattern." Covers the architectural choice (first-party brand-neutral utility vs developer-bundled), the model parser + substitution policy, the external-engine bridge pattern. Cites the precedent (Ollama + LM Studio) and explains how Hub differs (it's a *bridge* to those, not a replacement).
- VitePress sidebar update: add Hub guide entries under "Guide".

---

## Task 14 — End-to-end testing

Manual verification matrix:

| Test | Devices | Expected outcome |
|---|---|---|
| 1. Install Hub on Mac, mobile RN-app on iPhone, both same Wi-Fi | Mac + iPhone | Pairing notif fires; user approves; chat completion offloads; SSE streams |
| 2. Same as #1, on Windows | Win desktop + iPhone | Same flow, same outcome |
| 3. Two unrelated mobile apps pair with same Hub | iPhone (chat-app + journal-app) + Mac | Both pair independently; revoking one doesn't affect the other; audit log shows separate per-app entries |
| 4. App requests gemma-4-E2B-q4-instruct; Hub has gemma-4-E2B-q8-instruct cached; no substitute flag | iPhone + Mac | Hub refuses with no_capable_device |
| 5. Same as #4 but with X-DVAI-Substitute: prefer-better-quant | iPhone + Mac | Hub serves q8 model; response includes `usedModel: gemma-4-E2B-q8-instruct` |
| 6. App requests chat-typed model; Hub only has instruct-typed | iPhone + Mac | Hub refuses regardless of substitution flag |
| 7. Hub auto-detects Ollama running; user enables it; app requests Llama-3.2-3B-Instruct cached in Ollama | iPhone + Mac (with Ollama) | Hub routes to Ollama; response carries an audit-trail header |
| 8. Hub paused via tray icon mid-session; resumed | Mac | Pairings preserved; reconnects work |
| 9. Hub uninstall → reinstall: pairings + cache survive only if config dir not deleted | Mac | Document this clearly in the README |
| 10. Hub on Mac + mobile via deployed rendezvous server (different Wi-Fi networks) | iPhone (cellular) + Mac (Wi-Fi) | QR pair works; chat completion offloads through the rendezvous relay |

Document results in `docs/development/distributed-inference-testing.md`'s "Hub-specific tests" section.

---

## Task 15 — v3.1.0 release

1. Bump root `package.json` 3.0.0 → 3.1.0.
2. Run `node scripts/sync-versions.js` + `node scripts/sync-package-meta.js`.
3. Update `hub/src-tauri/Cargo.toml` and `tauri.conf.json` to 3.1.0.
4. Update `CHANGELOG.md` with `[3.1.0] — <date>` consolidated entry covering all Phase 4 work.
5. Verify all builds pass:
   - `pnpm install --ignore-scripts && pnpm -r run build` (workspace).
   - `bash scripts/build-all.sh` (per-platform builds where the host supports them).
   - `cd hub && pnpm install && pnpm tauri build` (Hub Tauri build on Windows / Mac via SSH).
6. Commit + tag `v3.1.0` + push.
7. GH Releases workflow fires automatically; binaries land on the Release page within ~30 min.
8. Homebrew formula + winget manifest update PRs fire; auto-merge after CI.
9. (Optional, manual on launch day) Tag-day announcement per `docs/marketing/CALENDAR.md`.

---

## What we deliberately are NOT doing in v3.1

- **App Store distribution** (parked per spec §10).
- **TensorRT-LLM wrapper** (parked per spec §10).
- **vLLM-as-wrapped-backend** (external-engine bridge covers locally-installed vLLM; wrapping it ourselves is parked).
- **Mobile version of Hub** (architectural non-goal per spec).
- **Multi-user shared Hub** (per-user install pattern only).
- **Auto-update on by default** (opt-in).
- **Hub running in headless mode on a server** — this is a desktop utility. Servers should use the `rendezvous/` server directly, not Hub.
- **TensorFlow / JAX / PyTorch wrapped backends** — out of scope; if a user has those running, the external-engine bridge can adapter them as a future extension.

## Final 3 gate (v3.1.0 is fully shipped)

- DVAI Hub binaries land on GitHub Releases for Windows / macOS / Linux.
- `brew install deepvoiceai/dvai-hub/dvai-hub` works.
- `winget install DeepVoiceAI.DVAIHub` works.
- A user with no other dvai-bridge setup runs the installer, completes the first-run wizard, pairs their iPhone running an example app, sees inference offload — happy path end-to-end.
- All 10 Hub-specific E2E tests in Task 14 pass.
- Public docs land; RESEARCH.md §12 addendum lands.
- v3.1.0 git tag pushed.

Phase 4 closed. v3.0 → v3.1 transition complete. Phase 5 territory (TensorRT-LLM wrapper / Redis-backed rendezvous scaling / persistent rendezvous-pairing) is post-v3.1 work.

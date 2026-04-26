# Phase 3 Foundation Implementation Plan (3A + 3B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract every Capacitor plugin's portable code into separate `*-core` packages so the same source serves the Capacitor wrapper and (in later sub-phases) the standalone native SDKs. Then migrate the Android MediaPipe backend from the deprecated `tasks-genai` SDK to LiteRT-LM in the freshly-extracted core package.

**Architecture:** 4 new `*-core` packages under `packages/` (ios-llama-core, ios-foundation-core, android-llama-core, android-mediapipe-core). The 3 capacitor-* packages refactor to thin wrappers depending on their cores. `MediaPipeBridge` interface neutralized to take `ByteArray` instead of `MPImage` so the bridge contract no longer leaks MediaPipe types. LiteRT-LM replaces `com.google.mediapipe:tasks-genai` in android-mediapipe-core. All Android native libs build with `-Wl,-z,max-page-size=16384` for Google's 2025 16 KB-page-size mandate; CI verifies via objdump.

**Tech Stack:** Swift 5.9+ / SPM (iOS), Kotlin 2.x + Gradle 8.x (Android), llama.cpp (pinned submodule), Telegraph (iOS HTTP), Ktor 2.x (Android HTTP), LiteRT-LM SDK (3B), Capacitor 8.x (existing wrappers).

**Spec:** [`docs/superpowers/specs/2026-04-26-phase3-foundation-design.md`](../specs/2026-04-26-phase3-foundation-design.md)

**Branch:** `feat/phase3-foundation` off `main`. Implementation done in worktree `.worktrees/phase3-foundation`.

**Phase boundaries (milestone checkpoints):**

- **Phase 3A — iOS core extractions** (Tasks 1-8): ios-llama-core + ios-foundation-core stand alone, all iOS XCTest unit tests pass.
- **Phase 3A — Android core extractions** (Tasks 9-12): android-llama-core + android-mediapipe-core stand alone, all Android JVM tests pass.
- **Phase 3A — Capacitor wrapper rewiring** (Tasks 13-15): all 3 capacitor-* packages compile + test against the new cores.
- **Phase 3A — 16 KB alignment + cap-sync verification** (Tasks 16-17): CI verifies alignment; manual cap-sync E2E test against a sample app passes.
- **Phase 3A milestone** (Task 18): all platforms green; commit + tag.
- **Phase 3B — LiteRT-LM migration** (Tasks 19-25): inventory, interface neutralization, build.gradle swap, bridge rewrite, test parity, milestone.

---

## Phase 3A — iOS llama core extraction

### Task 1: Scaffold `dvai-bridge-ios-llama-core` package

**Files:**
- Create: `packages/dvai-bridge-ios-llama-core/package.json`
- Create: `packages/dvai-bridge-ios-llama-core/ios/Package.swift`
- Create: `packages/dvai-bridge-ios-llama-core/.gitignore`
- Create: `packages/dvai-bridge-ios-llama-core/README.md`

- [ ] **Step 1: Make the directory**

```bash
mkdir -p packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore
mkdir -p packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/include
mkdir -p packages/dvai-bridge-ios-llama-core/ios/Tests/DVAILlamaCoreTests
```

- [ ] **Step 2: Write `packages/dvai-bridge-ios-llama-core/package.json`**

```json
{
  "name": "@dvai-bridge/ios-llama-core",
  "version": "1.6.0",
  "description": "DVAI-Bridge iOS llama.cpp core — pure Swift / ObjC++ embedded HTTP server + handlers + bridge. Capacitor-free.",
  "author": "Deep Chakraborty <https://github.com/dk013>",
  "license": "Custom (See LICENSE)",
  "main": "ios/Package.swift",
  "files": ["ios", "README.md", "LICENSE"],
  "publishConfig": {
    "access": "public"
  }
}
```

- [ ] **Step 3: Write a stub `Package.swift` with empty product (we'll fill in after files move)**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DVAILlamaCore",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "DVAILlamaCore", targets: ["DVAILlamaCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.40.0"),
    ],
    targets: [
        .target(
            name: "DVAILlamaCoreObjC",
            path: "ios/Sources/DVAILlamaCoreObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "DVAILlamaCore",
            dependencies: ["DVAILlamaCoreObjC", "Telegraph"],
            path: "ios/Sources/DVAILlamaCore"
        ),
        .testTarget(
            name: "DVAILlamaCoreTests",
            dependencies: ["DVAILlamaCore", "DVAILlamaCoreObjC"],
            path: "ios/Tests/DVAILlamaCoreTests"
        ),
    ]
)
```

- [ ] **Step 4: Write a brief README**

```markdown
# @dvai-bridge/ios-llama-core

Pure Swift / ObjC++ llama.cpp core for iOS. Embedded HTTP server (Telegraph),
OpenAI-compatible handlers, model downloader, content-parts translator, and
the ObjC++ bridge into llama.cpp / mtmd. **No Capacitor dependency.**

Used by:
- `@dvai-bridge/capacitor-llama` (Capacitor wrapper)
- `@dvai-bridge/ios` (Phase 3C — standalone iOS SDK; not yet shipped)
```

- [ ] **Step 5: Commit the empty scaffold**

```bash
git add packages/dvai-bridge-ios-llama-core/
git commit -m "chore(ios-llama-core): scaffold empty package"
```

### Task 2: Move iOS llama Internal/ + ObjC++ bridge files into the core package

**Files:**
- Move: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/*` → `packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/`
- Move: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlamaObjC/*` → `packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/`
- Modify: any `import` statements within moved files

- [ ] **Step 1: Move the Internal/ Swift files**

```bash
git mv packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/HttpServer.swift \
       packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/HttpServer.swift
git mv packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/HandlerContext.swift \
       packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/HandlerContext.swift
git mv packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/HandlerDispatch.swift \
       packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/HandlerDispatch.swift
git mv packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/LlamaHandlers.swift \
       packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/LlamaHandlers.swift
git mv packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/ContentPartsTranslator.swift \
       packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/ContentPartsTranslator.swift
git mv packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/PluginState.swift \
       packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/PluginState.swift
git mv packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/ModelDownloader.swift \
       packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/ModelDownloader.swift
git mv packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/ImageDecoder.swift \
       packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/ImageDecoder.swift
git mv packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/AudioDecoder.swift \
       packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/AudioDecoder.swift
git mv packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/LlamaCppBridgeProtocol.swift \
       packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/LlamaCppBridgeProtocol.swift
```

- [ ] **Step 2: Move the ObjC++ bridge files**

```bash
git mv packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlamaObjC/LlamaCppBridge.mm \
       packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/LlamaCppBridge.mm
git mv packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlamaObjC/include/LlamaCppBridge.h \
       packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/include/LlamaCppBridge.h
```

If there are any other files (e.g. `module.modulemap`, additional headers), move them similarly. The Capacitor wrapper's `DVAICapacitorLlamaObjC/` directory should end up empty and ready to delete.

- [ ] **Step 3: Update `import` statements in the moved Swift files**

Inside each moved Swift file under `DVAILlamaCore/`, replace `import DVAICapacitorLlamaObjC` with `import DVAILlamaCoreObjC`.

```bash
# Sanity check — list every Swift file that imports the ObjC bridge
grep -rln 'DVAICapacitorLlamaObjC' packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/
# Replace in each
sed -i 's/DVAICapacitorLlamaObjC/DVAILlamaCoreObjC/g' \
    packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/*.swift
```

- [ ] **Step 4: Run the Mac iOS build to confirm core package compiles**

```bash
pwsh scripts/mac-build.ps1 -Action build -Target ios-llama-core
```

(Add a `case ios-llama-core)` branch to `scripts/mac-side-build.sh` first — see Step 5.)

- [ ] **Step 5: Add ios-llama-core to mac-side-build.sh**

Modify `scripts/mac-side-build.sh` so the `case "$TARGET"` switch knows the new package:

```bash
case "$TARGET" in
  capacitor-llama)
    cd "packages/dvai-bridge-capacitor-llama/ios"
    SCHEME="DVAICapacitorLlama"
    ;;
  ios-llama-core)
    cd "packages/dvai-bridge-ios-llama-core/ios"
    SCHEME="DVAILlamaCore"
    ;;
  capacitor-foundation)
    # ... existing
esac
```

- [ ] **Step 6: Commit moves + import updates as a single commit**

Mixing the file moves with import updates in one commit keeps `git log --follow` working and makes the move reviewable as one atomic refactor.

```bash
git add -A
git commit -m "refactor(ios): move llama core sources into dvai-bridge-ios-llama-core package"
```

### Task 3: Move iOS llama Tests into the core package

**Files:**
- Move: `packages/dvai-bridge-capacitor-llama/ios/Tests/DVAICapacitorLlamaTests/{HttpServer,HandlerDispatch,LlamaHandlers,ContentPartsTranslator,PluginState,ModelDownloader,ImageDecoder,AudioDecoder,LlamaCppBridge}Test.swift` → `packages/dvai-bridge-ios-llama-core/ios/Tests/DVAILlamaCoreTests/`
- Stay: `RealModelSmokeTest.swift`, `SmokeTest.swift` stay in capacitor-llama

- [ ] **Step 1: Move the unit tests into the core package**

```bash
for t in HttpServer HandlerDispatch LlamaHandlers ContentPartsTranslator PluginState ModelDownloader ImageDecoder AudioDecoder LlamaCppBridge; do
    git mv "packages/dvai-bridge-capacitor-llama/ios/Tests/DVAICapacitorLlamaTests/${t}Test.swift" \
           "packages/dvai-bridge-ios-llama-core/ios/Tests/DVAILlamaCoreTests/${t}Test.swift"
done
```

- [ ] **Step 2: Update `@testable import` in moved test files**

Each moved test file has `@testable import DVAICapacitorLlama` at the top. Replace with `@testable import DVAILlamaCore`.

```bash
sed -i 's/@testable import DVAICapacitorLlama$/@testable import DVAILlamaCore/g' \
    packages/dvai-bridge-ios-llama-core/ios/Tests/DVAILlamaCoreTests/*.swift
```

Also any `import DVAICapacitorLlamaObjC` in the test files becomes `import DVAILlamaCoreObjC`.

```bash
sed -i 's/import DVAICapacitorLlamaObjC/import DVAILlamaCoreObjC/g' \
    packages/dvai-bridge-ios-llama-core/ios/Tests/DVAILlamaCoreTests/*.swift
```

- [ ] **Step 3: Add ios-llama-core to mac-side-test.sh**

Modify `scripts/mac-side-test.sh` similarly to Step 5 in Task 2:

```bash
ios-llama-core)
    cd "packages/dvai-bridge-ios-llama-core/ios"
    SCHEME="DVAILlamaCore"
    ;;
```

- [ ] **Step 4: Run the iOS XCTest suite for ios-llama-core on Mac**

```bash
pwsh scripts/mac-build.ps1 -Action test -Target ios-llama-core -Filter "!DVAILlamaCoreTests/RealModelSmokeTest"
```

(There won't actually be a smoke test in this package; the filter is harmless.)

Expected: 60+ tests pass (the same tests that ran under the Capacitor package before, minus the smoke + sanity tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(ios): move llama unit tests into dvai-bridge-ios-llama-core"
```

### Task 4: Wire Capacitor llama wrapper to consume `DVAILlamaCore`

**Files:**
- Modify: `packages/dvai-bridge-capacitor-llama/ios/Package.swift`
- Modify: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Plugin.swift`
- Modify: `packages/dvai-bridge-capacitor-llama/package.json` (add peerDependency)
- Delete: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/` (now empty)
- Delete: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlamaObjC/` (now empty)
- Delete: `packages/dvai-bridge-capacitor-llama/DVAICapacitorLlama.podspec` (or modify — see Step 4)

- [ ] **Step 1: Update Package.swift to depend on the core package**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DVAICapacitorLlama",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "DVAICapacitorLlama", targets: ["DVAICapacitorLlama"]),
    ],
    dependencies: [
        // Capacitor SPM artifact (existing)
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm", branch: "main"),
        // The new core — relative path during dev, replaced with version-pin or git URL at publish time
        .package(name: "DVAILlamaCore", path: "../../dvai-bridge-ios-llama-core/ios"),
    ],
    targets: [
        .target(
            name: "DVAICapacitorLlama",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                "DVAILlamaCore",
            ],
            path: "ios/Sources/DVAICapacitorLlama"
        ),
    ]
)
```

Test target removed (smoke test moves out of Sources Package — see Task 5).

- [ ] **Step 2: Add `import DVAILlamaCore` to Plugin.swift**

The existing Plugin.swift references `PluginState`, `LlamaCppBridge`, etc. via the same module. Now these come from `DVAILlamaCore`:

```swift
import Foundation
import Capacitor
import DVAILlamaCore  // <-- new

@objc(DVAIBridgeLlamaPlugin)
public class DVAIBridgeLlamaPlugin: CAPPlugin {
    private let state = PluginState()
    // ... rest unchanged; PluginState, LlamaCppBridge, ProgressEvent etc.
    // are now reached via the DVAILlamaCore module
}
```

If `Plugin.swift` references types like `LlamaCppBridge` (the ObjC class) directly, also add `import DVAILlamaCoreObjC`.

- [ ] **Step 3: Delete the now-empty old directories**

```bash
git rm -r packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/
git rm -r packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlamaObjC/
```

- [ ] **Step 4: Update the podspec to pull DVAILlamaCore source**

Open `packages/dvai-bridge-capacitor-llama/DVAICapacitorLlama.podspec` and change `s.source_files` to include the core package's source as well as the wrapper's:

```ruby
Pod::Spec.new do |s|
  s.name = 'DVAICapacitorLlama'
  s.version = '1.6.0'
  s.summary = 'DVAI-Bridge Capacitor plugin: llama.cpp on iOS+Android.'
  s.license = { :file => '../../LICENSE' }
  s.homepage = 'https://github.com/Westenets/dvai-bridge'
  s.author = { 'Deep Voice AI' => 'info@deepvoiceai.co' }
  s.source = { :git => 'https://github.com/Westenets/dvai-bridge.git', :tag => "v#{s.version}" }
  s.platform = :ios, '14.0'
  s.swift_version = '5.9'
  s.source_files = [
    'ios/Sources/DVAICapacitorLlama/**/*.{swift,m}',
    '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/**/*.swift',
    '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/**/*.{h,mm}',
  ]
  s.public_header_files = '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/include/*.h'
  s.dependency 'Capacitor'
  s.dependency 'Telegraph', '~> 0.40'
end
```

CocoaPods doesn't have inter-pod source references the same way SPM does, so we bundle both packages' sources into a single pod. The Capacitor consumer experience is unchanged.

- [ ] **Step 5: Update package.json to declare the core as a peerDependency**

```json
{
  "peerDependencies": {
    "@dvai-bridge/capacitor": "*",
    "@dvai-bridge/ios-llama-core": "*"
  }
}
```

- [ ] **Step 6: Build the Capacitor wrapper on Mac to verify everything links**

```bash
pwsh scripts/mac-build.ps1 -Action build -Target capacitor-llama
```

Expected: clean build, no missing symbols.

- [ ] **Step 7: Run the Capacitor wrapper's remaining test suite (smoke + sanity)**

```bash
pwsh scripts/mac-build.ps1 -Action test -Target capacitor-llama -Filter "!DVAICapacitorLlamaTests/RealModelSmokeTest"
```

Expected: only `SmokeTest.testHandlerContextInit` runs (the small sanity test that proves the Capacitor target compiles). 1 test, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(capacitor-llama,ios): wire wrapper to depend on DVAILlamaCore module"
```

### Task 5: Verify ios-llama-core full XCTest suite still passes

- [ ] **Step 1: Run the core's XCTest suite end-to-end**

```bash
pwsh scripts/mac-build.ps1 -Action test -Target ios-llama-core
```

Expected: same test count (60+) as ran inside the Capacitor wrapper before extraction.

- [ ] **Step 2: Compare counts against the pre-3A baseline**

Before this Phase started, `pwsh scripts/mac-build.ps1 -Action test -Target capacitor-llama -Filter "!DVAICapacitorLlamaTests/RealModelSmokeTest"` ran 65 tests including the unit tests + sanity test. After 3A:

- ios-llama-core runs 64 of those (unit tests).
- capacitor-llama runs 1 (the sanity SmokeTest).
- Sum: still 65. **Net coverage: unchanged.**

If counts don't match, do not proceed — investigate before moving on.

- [ ] **Step 3: No commit (verification only)**

---

## Phase 3A — iOS foundation core extraction

### Task 6: Scaffold + extract `dvai-bridge-ios-foundation-core`

The foundation plugin is much smaller than llama (~250 LOC of Swift, no ObjC++, no llama.cpp submodule). The same extraction recipe applies.

**Files:**
- Create: `packages/dvai-bridge-ios-foundation-core/package.json`
- Create: `packages/dvai-bridge-ios-foundation-core/ios/Package.swift`
- Move: `packages/dvai-bridge-capacitor-foundation/ios/Sources/DVAICapacitorFoundation/Internal/*` → `packages/dvai-bridge-ios-foundation-core/ios/Sources/DVAIFoundationCore/`

- [ ] **Step 1: Scaffold the package** (mirror Task 1's structure)

```bash
mkdir -p packages/dvai-bridge-ios-foundation-core/ios/Sources/DVAIFoundationCore
mkdir -p packages/dvai-bridge-ios-foundation-core/ios/Tests/DVAIFoundationCoreTests
```

Write `package.json`:

```json
{
  "name": "@dvai-bridge/ios-foundation-core",
  "version": "1.6.0",
  "description": "DVAI-Bridge iOS Foundation Models core — pure Swift embedded HTTP server + handlers wrapping Apple's LanguageModelSession. Capacitor-free. Requires iOS 26.0+ at runtime.",
  "license": "Custom (See LICENSE)",
  "main": "ios/Package.swift",
  "files": ["ios", "README.md", "LICENSE"]
}
```

Write `Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DVAIFoundationCore",
    platforms: [.iOS(.v18)],  // 18.1 link-time floor; runtime check for 26+ inside the code
    products: [
        .library(name: "DVAIFoundationCore", targets: ["DVAIFoundationCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.40.0"),
    ],
    targets: [
        .target(
            name: "DVAIFoundationCore",
            dependencies: ["Telegraph"],
            path: "ios/Sources/DVAIFoundationCore"
        ),
        .testTarget(
            name: "DVAIFoundationCoreTests",
            dependencies: ["DVAIFoundationCore"],
            path: "ios/Tests/DVAIFoundationCoreTests"
        ),
    ]
)
```

- [ ] **Step 2: Move all Internal/ Swift files**

```bash
git mv packages/dvai-bridge-capacitor-foundation/ios/Sources/DVAICapacitorFoundation/Internal/*.swift \
       packages/dvai-bridge-ios-foundation-core/ios/Sources/DVAIFoundationCore/
```

(Adjust if there are additional non-Internal/ portable files — inspect the directory first.)

- [ ] **Step 3: Move the unit tests**

```bash
git mv packages/dvai-bridge-capacitor-foundation/ios/Tests/DVAICapacitorFoundationTests/*.swift \
       packages/dvai-bridge-ios-foundation-core/ios/Tests/DVAIFoundationCoreTests/
```

Update `@testable import DVAICapacitorFoundation` → `@testable import DVAIFoundationCore` in each test file.

- [ ] **Step 4: Update mac-side-build.sh + mac-side-test.sh**

Add `ios-foundation-core` cases pointing at the new directory.

- [ ] **Step 5: Build + test**

```bash
pwsh scripts/mac-build.ps1 -Action test -Target ios-foundation-core
```

Expected: same test count (~11) as ran in capacitor-foundation before.

- [ ] **Step 6: Commit**

```bash
git commit -m "refactor(ios): extract Foundation Models core into dvai-bridge-ios-foundation-core"
```

### Task 7: Wire Capacitor foundation wrapper to consume `DVAIFoundationCore`

Mirror Task 4 for foundation.

**Files:**
- Modify: `packages/dvai-bridge-capacitor-foundation/ios/Package.swift`
- Modify: `packages/dvai-bridge-capacitor-foundation/ios/Sources/DVAICapacitorFoundation/Plugin.swift`
- Modify: `packages/dvai-bridge-capacitor-foundation/DVAICapacitorFoundation.podspec`
- Modify: `packages/dvai-bridge-capacitor-foundation/package.json` (add peerDep)
- Delete: empty `Internal/` directory

- [ ] **Step 1: Update Package.swift**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DVAICapacitorFoundation",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "DVAICapacitorFoundation", targets: ["DVAICapacitorFoundation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm", branch: "main"),
        .package(name: "DVAIFoundationCore", path: "../../dvai-bridge-ios-foundation-core/ios"),
    ],
    targets: [
        .target(
            name: "DVAICapacitorFoundation",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                "DVAIFoundationCore",
            ],
            path: "ios/Sources/DVAICapacitorFoundation"
        ),
    ]
)
```

- [ ] **Step 2: Add `import DVAIFoundationCore` to Plugin.swift**

- [ ] **Step 3: Update the podspec source_files to include both packages**

- [ ] **Step 4: Update package.json with peerDep on `@dvai-bridge/ios-foundation-core`**

- [ ] **Step 5: Build + sanity test**

```bash
pwsh scripts/mac-build.ps1 -Action build -Target capacitor-foundation
pwsh scripts/mac-build.ps1 -Action test -Target capacitor-foundation
```

- [ ] **Step 6: Commit**

```bash
git commit -m "refactor(capacitor-foundation,ios): wire wrapper to depend on DVAIFoundationCore module"
```

### Task 8: Phase 3A iOS milestone — both core packages green, both Capacitor wrappers green

- [ ] **Step 1: Run all four iOS targets**

```bash
pwsh scripts/mac-build.ps1 -Action test -Target ios-llama-core
pwsh scripts/mac-build.ps1 -Action test -Target capacitor-llama -Filter "!DVAICapacitorLlamaTests/RealModelSmokeTest"
pwsh scripts/mac-build.ps1 -Action test -Target ios-foundation-core
pwsh scripts/mac-build.ps1 -Action test -Target capacitor-foundation
```

- [ ] **Step 2: Verify total count matches pre-3A baseline (76 = 65 llama + 11 foundation, ignoring smoke)**

If matches, proceed. Else investigate.

- [ ] **Step 3: No commit (verification only)**

---

## Phase 3A — Android core extractions

### Task 9: Scaffold + extract `dvai-bridge-android-llama-core`

The Android side is parallel to iOS but differs in two ways:

1. Gradle uses project-relative module paths via `settings.gradle`, not SPM-style package URLs.
2. The llama.cpp git submodule and CMakeLists.txt move with the JNI bridge.

**Files:**
- Create: `packages/dvai-bridge-android-llama-core/package.json`
- Create: `packages/dvai-bridge-android-llama-core/android/build.gradle`
- Create: `packages/dvai-bridge-android-llama-core/android/settings.gradle`
- Create: `packages/dvai-bridge-android-llama-core/android/gradle.properties`
- Move: `packages/dvai-bridge-capacitor-llama/native/llama.cpp` → `packages/dvai-bridge-android-llama-core/android/src/main/cpp/llama.cpp` (note: this is a git submodule; submodule path moves)
- Move: `packages/dvai-bridge-capacitor-llama/android/src/main/cpp/*` → `packages/dvai-bridge-android-llama-core/android/src/main/cpp/`
- Move: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/{HttpServer,HandlerDispatch,LlamaHandlers,ContentPartsTranslator,PluginState,ModelDownloader,ImageDecoder,AudioDecoder,LlamaCppBridge}.kt` → `packages/dvai-bridge-android-llama-core/android/src/main/java/co/deepvoiceai/dvaibridge/llama/core/`

- [ ] **Step 1: Make directory structure**

```bash
mkdir -p packages/dvai-bridge-android-llama-core/android/src/main/{cpp,java/co/deepvoiceai/dvaibridge/llama/core,res/xml}
mkdir -p packages/dvai-bridge-android-llama-core/android/src/test/java/co/deepvoiceai/dvaibridge/llama/core
mkdir -p packages/dvai-bridge-android-llama-core/android/gradle/wrapper
```

- [ ] **Step 2: Write package.json**

```json
{
  "name": "@dvai-bridge/android-llama-core",
  "version": "1.6.0",
  "description": "DVAI-Bridge Android llama.cpp core — pure Kotlin + JNI embedded HTTP server + handlers + bridge. Capacitor-free.",
  "license": "Custom (See LICENSE)",
  "files": ["android", "README.md", "LICENSE"]
}
```

- [ ] **Step 3: Write build.gradle**

```gradle
buildscript {
    ext {
        kotlinVersion = '2.3.21'
    }
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath 'com.android.tools.build:gradle:9.2.0'
        classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion"
    }
}

ext {
    junitVersion = '4.13.2'
    androidxAppCompatVersion = '1.7.1'
    coroutinesVersion = '1.10.2'
    ktorVersion = '2.3.13'
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

apply plugin: 'com.android.library'

android {
    namespace 'co.deepvoiceai.dvaibridge.llama.core'
    compileSdk 36
    ndkVersion '27.0.12077973'  // r27+ defaults to 16 KB-aligned .so

    defaultConfig {
        minSdk 26
        targetSdk 36
        consumerProguardFiles 'consumer-rules.pro'
        externalNativeBuild {
            cmake {
                cppFlags '-std=c++17', '-Wl,-z,max-page-size=16384'  // 16 KB alignment
                arguments '-DANDROID_STL=c++_shared',
                          '-DLLAMA_STATIC=ON',
                          '-DGGML_LLAMAFILE=OFF'
            }
        }
        ndk {
            abiFilters 'arm64-v8a', 'x86_64'
        }
    }

    externalNativeBuild {
        cmake {
            path 'src/main/cpp/CMakeLists.txt'
            version '3.22.1'
        }
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = '17'
    }
    testOptions {
        unitTests {
            includeAndroidResources = true
            returnDefaultValues = true
        }
    }
}

dependencies {
    implementation "org.jetbrains.kotlin:kotlin-stdlib:$kotlinVersion"
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-core:$coroutinesVersion"
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:$coroutinesVersion"
    implementation "io.ktor:ktor-server-core:$ktorVersion"
    implementation "io.ktor:ktor-server-cio:$ktorVersion"
    implementation "io.ktor:ktor-server-status-pages:$ktorVersion"

    testImplementation "junit:junit:$junitVersion"
    testImplementation "org.jetbrains.kotlinx:kotlinx-coroutines-test:$coroutinesVersion"
    testImplementation 'org.robolectric:robolectric:4.13'
    testImplementation "com.squareup.okhttp3:mockwebserver:4.12.0"
}
```

- [ ] **Step 4: Write settings.gradle**

```gradle
include ':dvai-bridge-android-llama-core'
project(':dvai-bridge-android-llama-core').projectDir = file('.')
rootProject.name = 'dvai-bridge-android-llama-core'
```

- [ ] **Step 5: Move the JNI + CMakeLists.txt**

```bash
git mv packages/dvai-bridge-capacitor-llama/android/src/main/cpp/jni-bridge.cpp \
       packages/dvai-bridge-android-llama-core/android/src/main/cpp/jni-bridge.cpp
git mv packages/dvai-bridge-capacitor-llama/android/src/main/cpp/CMakeLists.txt \
       packages/dvai-bridge-android-llama-core/android/src/main/cpp/CMakeLists.txt
```

If there are any other files under `cpp/`, move them too.

- [ ] **Step 6: Move the llama.cpp submodule**

The submodule lives at `packages/dvai-bridge-capacitor-llama/native/llama.cpp/`. Moving a Git submodule requires a careful sequence: deinit, edit `.gitmodules`, move, re-init.

```bash
# Deinit the submodule from its current path
git submodule deinit packages/dvai-bridge-capacitor-llama/native/llama.cpp

# Move the submodule directory
git mv packages/dvai-bridge-capacitor-llama/native packages/dvai-bridge-android-llama-core/android/src/main/cpp/native

# Edit .gitmodules to reflect the new path (sed in-place)
sed -i 's|packages/dvai-bridge-capacitor-llama/native/llama.cpp|packages/dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp|g' .gitmodules

# Sync + re-init at the new location
git submodule sync
git submodule update --init packages/dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp
```

Update CMakeLists.txt's `add_subdirectory(...)` line to point at the new submodule path (relative paths inside the CMakeLists need adjusting if they referenced `../../native/llama.cpp`).

- [ ] **Step 7: Move the Kotlin source files**

```bash
for f in HttpServer HandlerDispatch LlamaHandlers ContentPartsTranslator PluginState ModelDownloader ImageDecoder AudioDecoder LlamaCppBridge; do
    git mv "packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/${f}.kt" \
           "packages/dvai-bridge-android-llama-core/android/src/main/java/co/deepvoiceai/dvaibridge/llama/core/${f}.kt"
done
```

- [ ] **Step 8: Update package declarations in moved Kotlin files**

```bash
sed -i 's|^package co.deepvoiceai.dvaibridge.llama$|package co.deepvoiceai.dvaibridge.llama.core|g' \
    packages/dvai-bridge-android-llama-core/android/src/main/java/co/deepvoiceai/dvaibridge/llama/core/*.kt
```

Cross-file references within the core need their imports updated; same regex.

- [ ] **Step 9: Move the JVM unit tests**

```bash
mkdir -p packages/dvai-bridge-android-llama-core/android/src/test/java/co/deepvoiceai/dvaibridge/llama/core
git mv packages/dvai-bridge-capacitor-llama/android/src/test/java/co/deepvoiceai/dvaibridge/llama/*Test.kt \
       packages/dvai-bridge-android-llama-core/android/src/test/java/co/deepvoiceai/dvaibridge/llama/core/

# Update package declarations + imports in tests
sed -i 's|^package co.deepvoiceai.dvaibridge.llama$|package co.deepvoiceai.dvaibridge.llama.core|g' \
    packages/dvai-bridge-android-llama-core/android/src/test/java/co/deepvoiceai/dvaibridge/llama/core/*.kt
sed -i 's|^import co.deepvoiceai.dvaibridge.llama\.|import co.deepvoiceai.dvaibridge.llama.core.|g' \
    packages/dvai-bridge-android-llama-core/android/src/test/java/co/deepvoiceai/dvaibridge/llama/core/*.kt
```

The androidTest tree (instrumented tests) follows in Step 10 — for the core, instrumented tests would just be ImageDecoder/AudioDecoder format-handling. The real-model smoke test stays in capacitor-llama.

- [ ] **Step 10: Move instrumented tests for the core (decoders, etc.) but keep RealModelSmokeTest in capacitor-llama**

Inspect `packages/dvai-bridge-capacitor-llama/android/src/androidTest/`. Move tests that exercise core code; keep those that exercise the Capacitor wrapper.

- [ ] **Step 11: Run the JVM tests on Windows directly**

```bash
cd packages/dvai-bridge-android-llama-core/android
./gradlew.bat testDebugUnitTest --no-daemon 2>&1 | tail -20
```

Expected: same test count as ran inside capacitor-llama before (53+ JVM tests).

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "refactor(android): move llama core sources into dvai-bridge-android-llama-core (incl. submodule + JNI)"
```

### Task 10: Wire Capacitor llama Android wrapper to consume the core

**Files:**
- Modify: `packages/dvai-bridge-capacitor-llama/android/build.gradle`
- Modify: `packages/dvai-bridge-capacitor-llama/android/settings.gradle`
- Modify: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/Plugin.kt`
- Modify: `packages/dvai-bridge-capacitor-llama/package.json`

- [ ] **Step 1: Update settings.gradle to include the core as a project dependency**

`packages/dvai-bridge-capacitor-llama/android/settings.gradle`:

```gradle
include ':dvai-bridge-android-llama-core'
project(':dvai-bridge-android-llama-core').projectDir = file('../../dvai-bridge-android-llama-core/android')
```

- [ ] **Step 2: Update build.gradle to depend on the core module**

`packages/dvai-bridge-capacitor-llama/android/build.gradle` (changes — full file maintained):

```gradle
android {
    namespace 'co.deepvoiceai.dvaibridge.llama'
    compileSdk 36

    defaultConfig {
        minSdk 26
        targetSdk 36
        // No NDK config here anymore — that lives in the core
    }
    // ... rest of compileOptions, kotlinOptions unchanged
}

dependencies {
    api project(':dvai-bridge-android-llama-core')   // re-export core's API to host apps
    implementation "com.getcapacitor:capacitor-android:$capacitorVersion"
    // ... existing other deps
}
```

The Capacitor wrapper has no NDK / CMake / cpp/ tree of its own anymore.

- [ ] **Step 3: Update Plugin.kt imports**

```kotlin
package co.deepvoiceai.dvaibridge.llama

import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.annotation.CapacitorPlugin
import co.deepvoiceai.dvaibridge.llama.core.PluginState  // <-- new package
import co.deepvoiceai.dvaibridge.llama.core.ProgressEvent  // <-- new package
// ... etc

@CapacitorPlugin(name = "DVAIBridgeLlama")
class Plugin : Plugin() {
    private val state = PluginState(...)
    // ... rest of class unchanged at the call-site level
}
```

- [ ] **Step 4: Update package.json with peerDep**

```json
{
  "peerDependencies": {
    "@dvai-bridge/capacitor": "*",
    "@dvai-bridge/android-llama-core": "*",
    "@dvai-bridge/ios-llama-core": "*"
  }
}
```

- [ ] **Step 5: Build the wrapper**

```bash
cd packages/dvai-bridge-capacitor-llama/android
./gradlew.bat assembleDebug --no-daemon 2>&1 | tail -20
```

Expected: clean build, no missing symbols. The core module is built as a project dependency.

- [ ] **Step 6: Run the Capacitor wrapper's remaining tests**

```bash
./gradlew.bat testDebugUnitTest --no-daemon 2>&1 | tail -20
```

Expected: minimal — only Plugin.kt-specific tests if any. Most have moved to the core.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(capacitor-llama,android): wrapper consumes android-llama-core via project dependency"
```

### Task 11: Scaffold + extract `dvai-bridge-android-mediapipe-core`

The mediapipe Android plugin doesn't have JNI / NDK / CMakeLists — MediaPipe ships pre-built `.so` files inside its AAR. So this extraction is simpler than the llama-core extraction in Task 9 (no submodule move, no native build config).

**Files:**
- Create: `packages/dvai-bridge-android-mediapipe-core/package.json`
- Create: `packages/dvai-bridge-android-mediapipe-core/android/build.gradle`
- Create: `packages/dvai-bridge-android-mediapipe-core/android/settings.gradle`
- Create: `packages/dvai-bridge-android-mediapipe-core/android/gradle.properties`
- Move: Kotlin source files from capacitor-mediapipe
- Move: JVM tests from capacitor-mediapipe

- [ ] **Step 1: Make directory structure**

```bash
mkdir -p packages/dvai-bridge-android-mediapipe-core/android/src/main/java/co/deepvoiceai/dvaibridge/mediapipe/core
mkdir -p packages/dvai-bridge-android-mediapipe-core/android/src/test/java/co/deepvoiceai/dvaibridge/mediapipe/core
mkdir -p packages/dvai-bridge-android-mediapipe-core/android/src/test/resources
mkdir -p packages/dvai-bridge-android-mediapipe-core/android/gradle/wrapper
```

- [ ] **Step 2: Write `package.json`**

```json
{
  "name": "@dvai-bridge/android-mediapipe-core",
  "version": "1.6.0",
  "description": "DVAI-Bridge Android MediaPipe LLM core — pure Kotlin embedded HTTP server + handlers wrapping the LiteRT-LM SDK. Capacitor-free.",
  "license": "Custom (See LICENSE)",
  "files": ["android", "README.md", "LICENSE"]
}
```

- [ ] **Step 3: Write `build.gradle` (note: still on tasks-genai 0.10.33 — Phase 3B will swap to LiteRT-LM)**

```gradle
buildscript {
    ext {
        kotlinVersion = '2.3.21'
    }
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath 'com.android.tools.build:gradle:9.2.0'
        classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion"
    }
}

ext {
    junitVersion = '4.13.2'
    androidxAppCompatVersion = '1.7.1'
    coroutinesVersion = '1.10.2'
    ktorVersion = '2.3.13'
    mediapipeGenaiVersion = '0.10.33'   // 3B replaces
    mediapipeCoreVersion = '0.10.33'    // 3B replaces
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

apply plugin: 'com.android.library'

android {
    namespace 'co.deepvoiceai.dvaibridge.mediapipe.core'
    compileSdk 36

    defaultConfig {
        minSdk 26
        targetSdk 36
    }
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = '17'
    }
    testOptions {
        unitTests {
            includeAndroidResources = true
            returnDefaultValues = true
        }
    }
}

dependencies {
    implementation "org.jetbrains.kotlin:kotlin-stdlib:$kotlinVersion"
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-core:$coroutinesVersion"
    implementation "io.ktor:ktor-server-core:$ktorVersion"
    implementation "io.ktor:ktor-server-cio:$ktorVersion"
    implementation "io.ktor:ktor-server-status-pages:$ktorVersion"

    // Phase 3A keeps tasks-genai; 3B replaces with LiteRT-LM in Tasks 16-19
    implementation "com.google.mediapipe:tasks-genai:$mediapipeGenaiVersion"
    implementation "com.google.mediapipe:tasks-core:$mediapipeCoreVersion"

    testImplementation "junit:junit:$junitVersion"
    testImplementation "org.jetbrains.kotlinx:kotlinx-coroutines-test:$coroutinesVersion"
    testImplementation 'org.robolectric:robolectric:4.13'
}
```

- [ ] **Step 4: Write `settings.gradle`**

```gradle
include ':dvai-bridge-android-mediapipe-core'
project(':dvai-bridge-android-mediapipe-core').projectDir = file('.')
rootProject.name = 'dvai-bridge-android-mediapipe-core'
```

- [ ] **Step 5: Move the Kotlin source files**

```bash
for f in HttpServer HandlerDispatch MediaPipeHandlers MediaPipeBridge ContentPartsTranslator PluginState ImageDecoder; do
    git mv "packages/dvai-bridge-capacitor-mediapipe/android/src/main/java/co/deepvoiceai/dvaibridge/mediapipe/${f}.kt" \
           "packages/dvai-bridge-android-mediapipe-core/android/src/main/java/co/deepvoiceai/dvaibridge/mediapipe/core/${f}.kt"
done
```

If your install of capacitor-mediapipe contains additional Kotlin files (check with `ls packages/dvai-bridge-capacitor-mediapipe/android/src/main/java/co/deepvoiceai/dvaibridge/mediapipe/` and exclude `Plugin.kt`), include them in the move too.

- [ ] **Step 6: Update package declarations + imports in moved source**

```bash
sed -i 's|^package co.deepvoiceai.dvaibridge.mediapipe$|package co.deepvoiceai.dvaibridge.mediapipe.core|g' \
    packages/dvai-bridge-android-mediapipe-core/android/src/main/java/co/deepvoiceai/dvaibridge/mediapipe/core/*.kt
sed -i 's|^import co.deepvoiceai.dvaibridge.mediapipe\.\([A-Z]\)|import co.deepvoiceai.dvaibridge.mediapipe.core.\1|g' \
    packages/dvai-bridge-android-mediapipe-core/android/src/main/java/co/deepvoiceai/dvaibridge/mediapipe/core/*.kt
```

- [ ] **Step 7: Move the JVM tests**

```bash
git mv packages/dvai-bridge-capacitor-mediapipe/android/src/test/java/co/deepvoiceai/dvaibridge/mediapipe/*Test.kt \
       packages/dvai-bridge-android-mediapipe-core/android/src/test/java/co/deepvoiceai/dvaibridge/mediapipe/core/

# Test resources (image fixtures, etc.) follow the tests
git mv packages/dvai-bridge-capacitor-mediapipe/android/src/test/resources/* \
       packages/dvai-bridge-android-mediapipe-core/android/src/test/resources/ 2>/dev/null || true

# Update package + imports in tests
sed -i 's|^package co.deepvoiceai.dvaibridge.mediapipe$|package co.deepvoiceai.dvaibridge.mediapipe.core|g' \
    packages/dvai-bridge-android-mediapipe-core/android/src/test/java/co/deepvoiceai/dvaibridge/mediapipe/core/*.kt
sed -i 's|^import co.deepvoiceai.dvaibridge.mediapipe\.\([A-Z]\)|import co.deepvoiceai.dvaibridge.mediapipe.core.\1|g' \
    packages/dvai-bridge-android-mediapipe-core/android/src/test/java/co/deepvoiceai/dvaibridge/mediapipe/core/*.kt
```

- [ ] **Step 8: Run JVM tests**

```bash
cd packages/dvai-bridge-android-mediapipe-core/android
./gradlew.bat testDebugUnitTest --no-daemon 2>&1 | tail -20
```

Expected: 24+ tests pass (same as ran inside capacitor-mediapipe before extraction).

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor(android): extract MediaPipe core into dvai-bridge-android-mediapipe-core (still on tasks-genai 0.10.33)"
```

### Task 12: Wire Capacitor mediapipe Android wrapper to consume the core

Like Task 10 (capacitor-llama Android wrapper) but for mediapipe. The wrapper drops its direct `tasks-genai` / `tasks-core` dependencies (those are now in the core) and gains a project-relative dependency on `:dvai-bridge-android-mediapipe-core`.

**Files:**
- Modify: `packages/dvai-bridge-capacitor-mediapipe/android/build.gradle`
- Modify: `packages/dvai-bridge-capacitor-mediapipe/android/settings.gradle`
- Modify: `packages/dvai-bridge-capacitor-mediapipe/android/src/main/java/co/deepvoiceai/dvaibridge/mediapipe/Plugin.kt`
- Modify: `packages/dvai-bridge-capacitor-mediapipe/package.json`

- [ ] **Step 1: Update `settings.gradle` to include the core**

```gradle
include ':dvai-bridge-android-mediapipe-core'
project(':dvai-bridge-android-mediapipe-core').projectDir = file('../../dvai-bridge-android-mediapipe-core/android')
```

- [ ] **Step 2: Update `build.gradle` to depend on the core module + drop direct mediapipe deps**

```gradle
dependencies {
    api project(':dvai-bridge-android-mediapipe-core')   // re-export core's API to host apps
    implementation "com.getcapacitor:capacitor-android:$capacitorVersion"
    // ... existing other deps EXCEPT tasks-genai and tasks-core
    // (those are now transitively pulled via the core)
}
```

The `ext { mediapipeGenaiVersion = ... }` block can stay in capacitor-mediapipe's build.gradle for backward compatibility but is unused.

- [ ] **Step 3: Update Plugin.kt imports**

```kotlin
package co.deepvoiceai.dvaibridge.mediapipe

import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.annotation.CapacitorPlugin
import co.deepvoiceai.dvaibridge.mediapipe.core.PluginState        // <-- new package
import co.deepvoiceai.dvaibridge.mediapipe.core.ProgressEvent      // <-- new package
// ... etc — every type that used to come from `co.deepvoiceai.dvaibridge.mediapipe`
//   now comes from `co.deepvoiceai.dvaibridge.mediapipe.core`

@CapacitorPlugin(name = "DVAIBridgeMediaPipe")
class Plugin : Plugin() {
    private val state = PluginState(...)
    // ... rest of the Plugin class is unchanged at the call-site level;
    //     the imports are the only change
}
```

- [ ] **Step 4: Update `package.json` with peerDep**

```json
{
  "peerDependencies": {
    "@dvai-bridge/capacitor": "*",
    "@dvai-bridge/android-mediapipe-core": "*"
  }
}
```

- [ ] **Step 5: Build the wrapper**

```bash
cd packages/dvai-bridge-capacitor-mediapipe/android
./gradlew.bat assembleDebug --no-daemon 2>&1 | tail -20
```

Expected: clean build, no missing symbols, no missing tasks-genai deps (they come transitively via the core).

- [ ] **Step 6: Run wrapper-side tests (whatever's left after the 3A core extraction)**

```bash
./gradlew.bat testDebugUnitTest --no-daemon 2>&1 | tail -20
```

Expected: minimal — only Plugin.kt-specific tests if any. The 24+ unit tests have moved to the core in Task 11.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(capacitor-mediapipe,android): wrapper consumes android-mediapipe-core via project dependency"
```

---

## Phase 3A — 16 KB page-size enforcement + cap-sync verification

### Task 13: 16 KB-alignment CI verification job

**Files:**
- Modify: `.github/workflows/test-android-llama-jvm.yml`

- [ ] **Step 1: Add a verification step after the assemble**

Open `.github/workflows/test-android-llama-jvm.yml` and append a step after the build:

```yaml
      - name: Verify 16 KB page-size alignment
        run: |
          set -e
          for so in $(find packages/dvai-bridge-android-llama-core/android/build -name '*.so'); do
            align=$(objdump -p "$so" | awk '/LOAD/ && /align 2\*\*[0-9]+/ { gsub(/2\*\*/, "", $NF); print $NF; exit }')
            page_size=$((1 << $align))
            if [ "$page_size" -lt "16384" ]; then
              echo "::error::$so has page alignment $page_size bytes, expected >= 16384"
              exit 1
            fi
            echo "$so: $page_size bytes — OK"
          done
```

`objdump -p`'s LOAD-segment alignment is shown as `align 2**N`; `2**14 = 16384`. We extract N, compute `1 << N`, and compare.

- [ ] **Step 2: Locally simulate the verification on a freshly-built `.so`**

```bash
cd packages/dvai-bridge-android-llama-core/android
./gradlew.bat assembleDebug --no-daemon
find build -name '*.so' -exec objdump -p {} \; | grep LOAD
```

Confirm at least one LOAD line shows `align 2**14` or higher.

- [ ] **Step 3: Commit**

```bash
git commit -m "ci(android): verify 16 KB page-size alignment on every llama-core build"
```

### Task 14: cap-sync E2E verification against a sample app

**Files:**
- Create: `scripts/verify-cap-sync.sh`

- [ ] **Step 1: Write the verification script**

```bash
#!/usr/bin/env bash
# scripts/verify-cap-sync.sh
#
# Bootstraps a throw-away Capacitor host app, installs all three
# capacitor-* plugins (and their cores), runs `cap sync`, builds for
# both iOS and Android, asserts the resulting projects link cleanly.
# This is the regression test that protects against "core package's
# Gradle module path doesn't get picked up by cap sync".

set -euo pipefail

TMP="$(mktemp -d)"
echo "[verify-cap-sync] using $TMP"

cd "$TMP"
npx --yes @capacitor/cli@8 init dvai-cap-test --web-dir www
mkdir www
echo '<html></html>' > www/index.html

# pnpm/npm install all relevant packages locally — adjust file: paths
# for whichever monorepo root we're in
REPO_ROOT="$1"
npm install --no-save \
  "${REPO_ROOT}/packages/dvai-bridge-capacitor" \
  "${REPO_ROOT}/packages/dvai-bridge-capacitor-llama" \
  "${REPO_ROOT}/packages/dvai-bridge-ios-llama-core" \
  "${REPO_ROOT}/packages/dvai-bridge-android-llama-core" \
  "${REPO_ROOT}/packages/dvai-bridge-capacitor-mediapipe" \
  "${REPO_ROOT}/packages/dvai-bridge-android-mediapipe-core" \
  "${REPO_ROOT}/packages/dvai-bridge-capacitor-foundation" \
  "${REPO_ROOT}/packages/dvai-bridge-ios-foundation-core"

npx cap add android
npx cap add ios
npx cap sync

# Verify Android Gradle resolves the core projects
cd android
./gradlew :app:assembleDebug --no-daemon

# Verify iOS Pods install (CocoaPods route)
cd ../ios/App
pod install

echo "[verify-cap-sync] OK"
rm -rf "$TMP"
```

- [ ] **Step 2: Run it from the repo root**

```bash
bash scripts/verify-cap-sync.sh "$PWD"
```

Expected: clean run, both Android assembleDebug and `pod install` succeed.

- [ ] **Step 3: If anything fails, the script's output points at the broken link — fix the relevant Package.swift / build.gradle / settings.gradle and re-run**

The most common failure is the iOS Capacitor wrapper's Package.swift referencing a sibling package via `path:` that doesn't actually exist after `npm install` flattens the structure. Adjust to the actual `node_modules/@dvai-bridge/...` resolved path.

- [ ] **Step 4: Commit**

```bash
git commit -m "chore(scripts): add verify-cap-sync.sh — E2E sync regression test"
```

### Task 15: Phase 3A milestone — verify all green and tag the work

- [ ] **Step 1: Run all test suites**

```bash
# JS
pnpm test

# Mac iOS — both core packages and both Capacitor wrappers
pwsh scripts/mac-build.ps1 -Action test -Target ios-llama-core
pwsh scripts/mac-build.ps1 -Action test -Target capacitor-llama -Filter "!DVAICapacitorLlamaTests/RealModelSmokeTest"
pwsh scripts/mac-build.ps1 -Action test -Target ios-foundation-core
pwsh scripts/mac-build.ps1 -Action test -Target capacitor-foundation

# Local Android — both core packages and both Capacitor wrappers
cd packages/dvai-bridge-android-llama-core/android && ./gradlew.bat testDebugUnitTest --no-daemon && cd ../../..
cd packages/dvai-bridge-capacitor-llama/android && ./gradlew.bat testDebugUnitTest --no-daemon && cd ../../..
cd packages/dvai-bridge-android-mediapipe-core/android && ./gradlew.bat testDebugUnitTest --no-daemon && cd ../../..
cd packages/dvai-bridge-capacitor-mediapipe/android && ./gradlew.bat testDebugUnitTest --no-daemon && cd ../../..

# E2E
bash scripts/verify-cap-sync.sh "$PWD"
```

- [ ] **Step 2: Verify total counts match the pre-3A baseline**

| Suite | Pre-3A | Post-3A | Delta |
|---|---|---|---|
| TS | 104 | 104 | 0 |
| iOS llama (unit + sanity) | 65 | 64+1 | 0 |
| iOS foundation | 11 | 11 | 0 |
| Android llama JVM | 53 | 53 | 0 |
| Android mediapipe JVM | 24 | 24 | 0 |

- [ ] **Step 3: Commit any cleanup + tag the milestone**

```bash
git commit --allow-empty -m "chore(phase3a): milestone — all 4 core packages green, all 3 capacitor wrappers green"
```

---

## Phase 3B — MediaPipe LiteRT-LM migration

### Task 16: Inventory LiteRT-LM API and write migration mapping doc

**Files:**
- Create: `docs/development/litert-lm-migration-notes.md`

- [ ] **Step 1: Web-fetch the LiteRT-LM API reference**

Reference URL (verify exact path is current at task time): https://ai.google.dev/edge/litert/llm/inference

The doc page should describe:
- Maven artifact ID (e.g. `com.google.ai.edge.litert:litert-lm:X.Y.Z`)
- Engine creation API (replacement for `LlmInference.createFromOptions`)
- Session API (replacement for `LlmInferenceSession`)
- Image input API (replacement for `addImage(MPImage)`)
- Streaming API (replacement for `generateResponseAsync`)
- Model file format (still `.task`? or `.litertmodel`?)

- [ ] **Step 2: Write a side-by-side mapping table**

In `docs/development/litert-lm-migration-notes.md`:

```markdown
# LiteRT-LM migration mapping (3B reference)

Source-of-truth API references at time of writing:
- LiteRT-LM SDK: https://ai.google.dev/edge/litert/llm/inference (verify current)
- Old tasks-genai 0.10.33 reference: https://developers.google.com/mediapipe/api/solutions/java/com/google/mediapipe/tasks/genai/llminference/package-summary

## Artifact coordinates

| Old | New |
|---|---|
| `com.google.mediapipe:tasks-genai:0.10.33` | `com.google.ai.edge.litert.lm:litert-lm:<VERSION>` |
| `com.google.mediapipe:tasks-core:0.10.33` | (subsumed?) |

## Class mappings

| Old (tasks-genai) | New (LiteRT-LM) |
|---|---|
| `LlmInference` | `???` |
| `LlmInference.LlmInferenceOptions.Builder` | `???` |
| `LlmInferenceSession` | `???` |
| `LlmInferenceSession.LlmInferenceSessionOptions.Builder` | `???` |
| `GraphOptions` | `???` |
| `MPImage` | `???` |

## Method mappings

| Old | New |
|---|---|
| `LlmInference.createFromOptions(context, options)` | `???` |
| `session.addQueryChunk(prompt)` | `???` |
| `session.addImage(MPImage)` | `???` |
| `session.generateResponse()` | `???` |
| `session.generateResponseAsync(listener)` | `???` |

## Behavioural deltas to watch

- (filled in during inventory)
```

Fill in the `???` cells from the API reference.

- [ ] **Step 3: Commit the inventory doc**

```bash
git commit -m "docs(litert-lm): inventory + mapping for the migration"
```

### Task 17: Neutralize `MediaPipeBridgeApi` interface (replace `MPImage` with `ByteArray`)

**Files:**
- Modify: `packages/dvai-bridge-android-mediapipe-core/android/src/main/java/co/deepvoiceai/dvaibridge/mediapipe/core/MediaPipeBridge.kt`

- [ ] **Step 1: Identify all interface methods that take `MPImage`**

```bash
grep -n "MPImage" packages/dvai-bridge-android-mediapipe-core/android/src/main/java/co/deepvoiceai/dvaibridge/mediapipe/core/MediaPipeBridge.kt
```

Most likely the `MediaPipeBridgeApi` interface declares `completePrompt(prompt: String, images: List<MPImage>)` and a streaming variant.

- [ ] **Step 2: Change the interface to `List<ByteArray>`**

```kotlin
// MediaPipeBridge.kt — interface section
interface MediaPipeBridgeApi {
    fun loadModel(...): Boolean
    fun unload()
    fun completePrompt(prompt: String, images: List<ByteArray> = emptyList()): String
    fun streamPrompt(
        prompt: String,
        images: List<ByteArray> = emptyList(),
        onToken: (String) -> Unit,
        onDone: (FinishReason) -> Unit
    )
    fun isVisionCapable(): Boolean
}
```

The implementing class continues to convert `ByteArray` → `MPImage` internally (during 3A's Pass A — Pass B replaces this with LiteRT-LM's image type).

- [ ] **Step 3: Update the implementation to accept ByteArray + convert to MPImage internally**

```kotlin
override fun completePrompt(prompt: String, images: List<ByteArray>): String {
    val mpImages = images.map { bytes ->
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw IllegalArgumentException("invalid image bytes")
        BitmapImageBuilder(bitmap).build()
    }
    val session = LlmInferenceSession.createFromOptions(engine(), sessionOptions())
    session.use { s ->
        s.addQueryChunk(prompt)
        mpImages.forEach { s.addImage(it) }
        return s.generateResponse()
    }
}
```

- [ ] **Step 4: Update `MediaPipeHandlers` if it was passing `MPImage` directly**

```bash
grep -n "MPImage" packages/dvai-bridge-android-mediapipe-core/android/src/main/java/co/deepvoiceai/dvaibridge/mediapipe/core/MediaPipeHandlers.kt
```

If MediaPipeHandlers builds `MPImage` instances, that conversion logic moves into `MediaPipeBridge.completePrompt`. Handlers now pass raw `ByteArray` (from `ContentPartsTranslator`).

- [ ] **Step 5: Update mock bridges in tests**

Find every `class FakeMediaPipeBridge` / `MockBridge` / `class TestBridge` in the test source and switch their `completePrompt` signatures to `List<ByteArray>`.

- [ ] **Step 6: Run JVM tests**

```bash
cd packages/dvai-bridge-android-mediapipe-core/android
./gradlew.bat testDebugUnitTest --no-daemon
```

Expected: 24+ tests pass with the neutralized interface.

- [ ] **Step 7: Commit**

```bash
git commit -m "refactor(mediapipe-core): neutralize MediaPipeBridgeApi — List<ByteArray> instead of List<MPImage>"
```

### Task 18: Swap `tasks-genai` for LiteRT-LM in build.gradle

**Files:**
- Modify: `packages/dvai-bridge-android-mediapipe-core/android/build.gradle`

- [ ] **Step 1: Update the `ext` block + `dependencies` block**

```gradle
ext {
    // (replace the two old vars with the LiteRT-LM artifact)
    litertLmVersion = '<VERSION_FROM_TASK_16>'
}

dependencies {
    implementation "com.google.ai.edge.litert.lm:litert-lm:$litertLmVersion"
    // tasks-genai + tasks-core lines deleted
}
```

- [ ] **Step 2: Try to compile — expect failures from MediaPipeBridge.kt's old imports**

```bash
./gradlew.bat compileDebugKotlin --no-daemon 2>&1 | tail -30
```

Compilation will break on the old imports (`com.google.mediapipe.tasks.genai.llminference.*`, `com.google.mediapipe.framework.image.MPImage`). That's expected — Task 19 fixes it.

- [ ] **Step 3: Commit the build.gradle change in isolation**

```bash
git commit -m "chore(mediapipe-core): swap tasks-genai for LiteRT-LM — compile broken until Task 19"
```

### Task 19: Rewrite `MediaPipeBridge` against LiteRT-LM

**Files:**
- Modify: `packages/dvai-bridge-android-mediapipe-core/android/src/main/java/co/deepvoiceai/dvaibridge/mediapipe/core/MediaPipeBridge.kt`

- [ ] **Step 1: Replace imports with LiteRT-LM equivalents (per Task 16's mapping)**

```kotlin
// New imports — exact names per LiteRT-LM API reference
import com.google.ai.edge.litert.lm.LlmEngine        // (placeholder — actual name from inventory)
import com.google.ai.edge.litert.lm.LlmSession       // (placeholder)
import com.google.ai.edge.litert.lm.SessionOptions   // (placeholder)
// ...etc per the mapping doc

// Old imports — DELETE
// import com.google.mediapipe.framework.image.MPImage
// import com.google.mediapipe.tasks.genai.llminference.GraphOptions
// import com.google.mediapipe.tasks.genai.llminference.LlmInference
// import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
```

- [ ] **Step 2: Replace engine creation**

```kotlin
private val engine: LlmEngine by lazy {
    LlmEngine.builder()
        .setModelPath(modelPath)
        .setMaxNumImages(maxImages)
        .setEnableVisionModality(visionEnabled)
        // ... whatever LiteRT-LM exposes
        .build(context)
}
```

- [ ] **Step 3: Replace session pattern**

```kotlin
override fun completePrompt(prompt: String, images: List<ByteArray>): String {
    val session = engine.newSession(SessionOptions.builder()
        .setTopK(topK)
        .setTemperature(temperature)
        .build())
    session.use { s ->
        s.addText(prompt)                    // or whatever LiteRT-LM names the chunk-add
        images.forEach { bytes ->
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                ?: throw IllegalArgumentException("invalid image bytes")
            s.addImage(bitmap)               // LiteRT-LM may take Bitmap directly; verify
        }
        return s.generateResponse()
    }
}
```

- [ ] **Step 4: Replace streaming**

LiteRT-LM may expose streaming as a Kotlin `Flow<String>` natively. If so:

```kotlin
override fun streamPrompt(
    prompt: String,
    images: List<ByteArray>,
    onToken: (String) -> Unit,
    onDone: (FinishReason) -> Unit
) {
    val session = engine.newSession(...)
    session.use { s ->
        s.addText(prompt)
        // images...
        runBlocking {
            s.generateStream().collect { chunk ->
                onToken(chunk)
            }
        }
        onDone(FinishReason.STOP)
    }
}
```

If it's still listener-based, the existing coroutine-wrapping pattern in our code carries over.

- [ ] **Step 5: Compile**

```bash
./gradlew.bat compileDebugKotlin --no-daemon 2>&1 | tail -20
```

Expected: clean.

- [ ] **Step 6: Run JVM tests**

```bash
./gradlew.bat testDebugUnitTest --no-daemon 2>&1 | tail -20
```

Expected: 24+ tests pass. If a test fails because mocked LiteRT-LM types don't match real LiteRT-LM behaviour, write a small adjustment but **do not change the bridge interface**.

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(mediapipe-core): MediaPipeBridge implementation switched to LiteRT-LM"
```

### Task 20: Verify capacitor-mediapipe wrapper still compiles + tests

The Capacitor wrapper depends on the core via project path; it should "just work" after the core's internal rewrite.

- [ ] **Step 1: Build the wrapper**

```bash
cd packages/dvai-bridge-capacitor-mediapipe/android
./gradlew.bat assembleDebug --no-daemon
```

- [ ] **Step 2: Run wrapper-side tests (whatever's left after the 3A core extraction)**

```bash
./gradlew.bat testDebugUnitTest --no-daemon
```

- [ ] **Step 3: No commit (verification only)**

### Task 21: Update CHANGELOG with the migration

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add a 1.7.0 entry covering Phase 3A + 3B**

```markdown
## 1.7.0 — 2026-04-26

### Added

- New `*-core` packages: `@dvai-bridge/ios-llama-core`, `@dvai-bridge/ios-foundation-core`, `@dvai-bridge/android-llama-core`, `@dvai-bridge/android-mediapipe-core`. Each is a Capacitor-free re-export of the corresponding plugin's portable code. These will be the foundation for the standalone iOS / Android / cross-framework SDKs in upcoming sub-phases.
- 16 KB Android page-size alignment enforced and verified in CI (`-Wl,-z,max-page-size=16384` on llama-core's NDK build; `objdump -p` check in the JVM workflow).

### Changed

- `@dvai-bridge/capacitor-llama`, `@dvai-bridge/capacitor-foundation`, and `@dvai-bridge/capacitor-mediapipe` are now thin wrappers that depend on their respective `*-core` packages. Host apps must install both the wrapper and its core(s) — the wrapper's `package.json` lists them as `peerDependencies` and the install error is actionable.
- `MediaPipeBridgeApi.completePrompt` and `streamPrompt` now take `List<ByteArray>` instead of `List<MPImage>`, so the bridge interface no longer leaks MediaPipe types. Internal-only change; no Capacitor / public JS API impact.
- `@dvai-bridge/android-mediapipe-core` migrated from `com.google.mediapipe:tasks-genai:0.10.33` (`@Deprecated` since 0.10.27) to `com.google.ai.edge.litert.lm:litert-lm:<VERSION>`. Same handler behaviour; same Capacitor JS contract; cleaner non-deprecated API surface internally.

### Removed

- `tasks-genai` and `tasks-core` Maven dependencies.
- `MPImage` references from `MediaPipeBridge` interface (still used internally during the migration's Pass A; removed in Pass B).
```

- [ ] **Step 2: Commit**

```bash
git commit -m "docs(changelog): 1.7.0 — Phase 3A + 3B"
```

### Task 22: Phase 3B milestone

- [ ] **Step 1: Run the entire test matrix one more time**

```bash
pnpm test  # 104 expected
pwsh scripts/mac-build.ps1 -Action test -Target ios-llama-core
pwsh scripts/mac-build.ps1 -Action test -Target capacitor-llama -Filter "!DVAICapacitorLlamaTests/RealModelSmokeTest"
pwsh scripts/mac-build.ps1 -Action test -Target ios-foundation-core
pwsh scripts/mac-build.ps1 -Action test -Target capacitor-foundation
cd packages/dvai-bridge-android-llama-core/android && ./gradlew.bat testDebugUnitTest --no-daemon && cd ../../..
cd packages/dvai-bridge-capacitor-llama/android && ./gradlew.bat testDebugUnitTest --no-daemon && cd ../../..
cd packages/dvai-bridge-android-mediapipe-core/android && ./gradlew.bat testDebugUnitTest --no-daemon && cd ../../..
cd packages/dvai-bridge-capacitor-mediapipe/android && ./gradlew.bat testDebugUnitTest --no-daemon && cd ../../..
bash scripts/verify-cap-sync.sh "$PWD"
```

- [ ] **Step 2: Verify counts (post-3B baseline matches post-3A baseline)**

| Suite | Post-3A | Post-3B | Delta |
|---|---|---|---|
| TS | 104 | 104 | 0 |
| iOS llama | 65 | 65 | 0 |
| iOS foundation | 11 | 11 | 0 |
| Android llama JVM | 53 | 53 | 0 |
| Android mediapipe JVM | 24 | 24 (LiteRT-LM-backed) | 0 |

- [ ] **Step 3: Commit milestone marker**

```bash
git commit --allow-empty -m "chore(phase3b): milestone — LiteRT-LM migration complete, all tests green"
```

---

## Definition of done

- [ ] 4 new `*-core` packages exist and build standalone.
- [ ] 3 capacitor-* packages refactored to depend on their cores; no native source code outside the core packages.
- [ ] All TS / iOS XCTest / Android JVM tests that pass on `main` pre-3A continue to pass post-3B.
- [ ] 16 KB-page-size CI verification job is green on every Android build.
- [ ] LiteRT-LM successfully replaces `tasks-genai` in `android-mediapipe-core`.
- [ ] All 24+ MediaPipe JVM tests pass against LiteRT-LM.
- [ ] `MediaPipeBridge` interface no longer leaks any MediaPipe / LiteRT-LM types (interface neutralization complete).
- [ ] `cap sync` end-to-end test passes against a freshly-set-up Capacitor host app for all three plugins.
- [ ] Branch merged to main with a clean rebase + fast-forward.
- [ ] Release tag `v1.7.0` published on `main` after merge.

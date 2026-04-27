# Contributing: .NET SDK

This page covers the local build + test loop for contributors working on
the .NET slice. For end-user docs see [dotnet-sdk.md](/guide/dotnet-sdk).

The .NET package ships as **six csproj's** under
`packages/dvai-bridge-dotnet/src/`: `DVAIBridge` (the cross-platform
core), `DVAIBridge.iOS`, `DVAIBridge.Android`, `DVAIBridge.Desktop`
(llama.cpp on Windows / Linux / macOS), `DVAIBridge.OnnxRuntime`, and
`DVAIBridge.MLNet`. Tests live under `tests/` mirroring the source
layout.

## Prerequisites

- **.NET SDK 10.0.203 LTS** (exact pin). The repo's `global.json`
  pins the SDK band with `rollForward: latestFeature`, so any 10.0.x
  feature release at or above the floor will resolve. Install via the
  `dotnet-install` script; the SDK is published on
  <https://dot.net>.

- **Workloads** — required for the iOS / Mac Catalyst / Android
  target frameworks:

  ```bash
  # macOS — full set including Apple-platform workloads:
  sudo dotnet workload install ios maccatalyst android

  # Windows / Linux — iOS and Mac Catalyst aren't supported here;
  # install only the Android workload:
  dotnet workload install android
  ```

- **Xcode 16+** on Mac hosts (required for the iOS + Mac Catalyst
  workloads' native bindings).
- **Android SDK 36** with `ANDROID_HOME` set, on any host that builds
  `DVAIBridge.Android`.

## Build + test loop

```bash
cd packages/dvai-bridge-dotnet

# Restore + build everything in the solution that's targetable on this host.
dotnet restore
dotnet build -c Release

# Run the four testable projects (each with its own csproj):
dotnet test tests/DVAIBridge.Tests
dotnet test tests/DVAIBridge.Desktop.Tests
dotnet test tests/DVAIBridge.OnnxRuntime.Tests
dotnet test tests/DVAIBridge.MLNet.Tests
```

### llama.cpp binary fetch (Desktop backend)

`DVAIBridge.Desktop` links against prebuilt `llama.cpp` binaries that
aren't checked into the repo. Fetch + verify before the first build:

```bash
cd packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop
bash scripts/fetch-llama-binaries.sh
bash scripts/verify-llama-checksums.sh
```

These scripts download the pinned `llama.cpp` release (`b8946`) for
each RID (`win-x64`, `linux-x64`, `osx-arm64`) into the package's
`runtimes/` folder, then SHA-256-verify against checksums committed
alongside the scripts. Re-run after a release-tag bump or when adding
a new RID.

### TFM rationale: `net10.0-ios26.2` (not `18.0`)

The iOS / Mac Catalyst NuGet packs target `net10.0-ios26.2` and
`net10.0-maccatalyst26.2`. We picked the **26.2** TFM (not the older
`net10.0-ios18.0`) because Apple's iOS 26 SDK is what Xcode 26 ships
with, and the `26.2` TFM is the one that resolves cleanly when a MAUI
or Avalonia consumer is itself targeting `net10.0-ios26.2`. The runtime
floor is still iOS 15.1 / Mac Catalyst 15.1 — TFM ≠ minimum OS. See
[Migration v2.3 → v2.4](/migration/v2.3-to-v2.4) for the full reasoning
and the consumer-side knock-on changes.

### Mac Catalyst host requirement

Only **macOS hosts** can pack the Mac Catalyst slice — the
`net10.0-maccatalyst26.2` TFM requires the iOS / Mac Catalyst workloads
that don't install on Windows or Linux. On a Windows dev box, expect
`dotnet build` to skip the Catalyst project gracefully; for a release
pack run, fall back to the Mac via [Mac remote builds](./mac-remote-builds.md).

## Common breakage modes

- **`workload not installed`** — re-run the workload install with
  `dotnet workload install ...`. If you bumped the SDK, also run
  `dotnet workload update`.
- **`net10.0-ios26.2` not found** — Xcode is too old, or the iOS
  workload isn't installed. Update Xcode to 16+ and re-run the workload
  install.
- **Stale `bin/` after a TFM bump** — `dotnet clean && dotnet
  restore`. The `obj/` cache otherwise pins the previous TFM resolution.
- **llama.cpp binary checksum mismatch** — your fetch was interrupted.
  Delete the downloaded files under
  `src/DVAIBridge.Desktop/runtimes/` and re-run
  `src/DVAIBridge.Desktop/scripts/fetch-llama-binaries.sh`.
- **Catalyst pack fails on Windows** — expected. Pack the Catalyst
  slice from a Mac, or skip it with
  `dotnet pack -p:TargetFrameworks=net10.0-android36.0\;net10.0`.

## Related

- [.NET SDK guide](/guide/dotnet-sdk) — user-facing API.
- [Migration v2.3 → v2.4](/migration/v2.3-to-v2.4) — the v2.4 TFM bump
  + consumer-side migration steps.
- [Mac remote builds](./mac-remote-builds.md) — for Catalyst / iOS
  packs from a Windows / Linux dev box.
- [Testing](./testing.md) — full layer-by-layer test guide.

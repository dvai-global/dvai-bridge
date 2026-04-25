# Mac remote builds

iOS XCTest cannot run on Windows or Linux. The DVAI-Bridge dev workflow
solves this with an SSH-based wrapper: a small PowerShell script on the
dev machine connects to a Mac, `git pull`s the worktree there, runs
`xcodebuild`, and streams output back. CI uses the same Mac as a
self-hosted GitHub Actions runner.

This page covers the developer-side setup. **All values shown are
placeholders** — your Mac's hostname, IP, username, and repo path stay
in a gitignored config file and never reach the repository.

## Why we use it

- iOS XCTest requires a Mac runner. Renting CI minutes on hosted macOS
  is expensive and slow to spin up; a self-hosted Mac caches simulators
  and DerivedData and runs ~3× faster.
- Most contributors work primarily on Windows / Linux. Round-tripping
  to a Mac shell is the smallest unit of friction that keeps the
  ergonomics workable.
- CI uses the same Mac via a self-hosted ARM64 runner. Same machine,
  same toolchain, no "works on my CI doesn't work locally" surprises.

## Setup (one-time)

### 1. Mac side

On the Mac that will host both your remote builds and the CI runner:

- Xcode 26+ installed via the App Store. Open Xcode once to accept the
  license and let it download the iOS SDK + the Metal toolchain.
- A simulator runtime that matches the destination string in
  `scripts/mac-side-build.sh` (currently `iOS 18.5, iPhone 16` —
  adjust the script if you target a different runtime).
- JDK 21 + Android command-line tools, **only if** you want to run
  Android instrumented tests on the Mac too. Most contributors run
  Android tests directly on their dev box.
- Clone the repo to a path of your choosing, e.g.
  `<path-to-repo-on-mac>/dvai-edge`.

### 2. SSH key auth from dev box → Mac

```bash
# On the dev box (Windows: PowerShell or Git Bash; Linux: any shell):
ssh-keygen -t ed25519 -C "dvai-mac"
ssh-copy-id <your-username>@<example-mac-host>
```

(On Windows without `ssh-copy-id`, paste the contents of
`~/.ssh/id_ed25519.pub` into `~/.ssh/authorized_keys` on the Mac
manually.)

Add an SSH alias in `~/.ssh/config`:

```
Host <your-ssh-alias>
    HostName <example-mac-host>
    User <your-username>
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 30
```

Verify:

```bash
ssh <your-ssh-alias> 'uname -a && xcodebuild -version'
```

### 3. Local config file

In the worktree, create `scripts/mac.local.json`. **This file is
gitignored** (`.gitignore` already has `scripts/mac.local.json` and
`scripts/*.local.json` and `.env.local`):

```json
{
  "sshAlias": "<your-ssh-alias>",
  "repoPath": "<path-to-repo-on-mac>/dvai-edge"
}
```

Or, equivalently, set environment variables instead of the file:

```bash
export DVAI_MAC_SSH_ALIAS=<your-ssh-alias>
export DVAI_MAC_REPO_PATH=<path-to-repo-on-mac>/dvai-edge
```

The wrapper reads the file first, then falls back to env vars.

### 4. Mac-side helpers

`scripts/mac-side-{build,test,clean}.sh` are committed in the repo and
run on the Mac (over SSH). You don't need to install or copy anything
extra — `git pull` on the Mac picks them up.

## Usage

From the dev box, in the worktree root:

```powershell
# Build only (compile-check):
pwsh -File scripts/mac-build.ps1 -Action build -Target capacitor-llama
pwsh -File scripts/mac-build.ps1 -Action build -Target capacitor-foundation
pwsh -File scripts/mac-build.ps1 -Action build -Target capacitor-mediapipe

# Run tests:
pwsh -File scripts/mac-build.ps1 -Action test  -Target capacitor-llama
pwsh -File scripts/mac-build.ps1 -Action test  -Target capacitor-foundation
pwsh -File scripts/mac-build.ps1 -Action test  -Target capacitor-mediapipe

# Filter to a single test:
pwsh -File scripts/mac-build.ps1 -Action test  -Target capacitor-llama \
     -Filter DVAICapacitorLlamaTests/LlamaHandlersTest/testStreamingFinishFrame

# Clean DerivedData / build artifacts:
pwsh -File scripts/mac-build.ps1 -Action clean -Target capacitor-llama
```

The wrapper:

1. Reads `mac.local.json` (or env vars) for the SSH alias + repo path.
2. SSHes to the Mac and `git pull --ff-only`s the repo there.
3. Runs `bash scripts/mac-side-<action>.sh <target> [<filter>]`.
4. Streams stdout / stderr back; exits with the remote exit code.

You commit and push from the dev box; the Mac pulls the same branch on
each invocation. Don't edit on the Mac — drift between the two trees is
the most common source of "passes on my Mac, fails in CI" surprises.

## Self-hosted CI runner

The same Mac is registered as a GitHub Actions self-hosted runner. The
workflows reference it via the **generic** label set
`[self-hosted, macOS, ARM64]` — no machine-specific identifiers.

Registration:

1. In the GitHub repo settings → Actions → Runners → "New self-hosted
   runner."
2. Follow the OS-specific instructions on the Mac. Use the labels
   `self-hosted`, `macOS`, `ARM64`. The token shown is single-use and
   expires within ~1 hour.
3. Run the runner as a launchd service:
   `./svc.sh install && ./svc.sh start`.
4. Verify a workflow can pick it up — `gh workflow run test-ios-llama.yml`
   from any clone.

## Troubleshooting

### "xcodebuild: error: Result bundle path already exists"

`mac-side-test.sh` already runs `rm -rf build/test-results.xcresult`
before each test pass. If you still hit this, the test was killed
mid-run and a stale lock survived. SSH in and clear it manually:

```bash
ssh <your-ssh-alias> 'cd <path-to-repo-on-mac>/dvai-edge/packages/dvai-bridge-capacitor-llama/ios && rm -rf build/'
```

### Simulator runtime mismatch

```
xcodebuild: error: Unable to find a destination matching ...
```

The destination string in `scripts/mac-side-{build,test}.sh` is
hard-pinned (currently `iPhone 16, iOS 18.5`). If your Mac doesn't have
that runtime installed, either install it via Xcode → Settings →
Components, or override per-invocation:

```bash
ssh <your-ssh-alias> 'IOS_DEST="platform=iOS Simulator,name=iPhone 15,OS=17.5" \
  bash <path-to-repo-on-mac>/dvai-edge/scripts/mac-side-test.sh capacitor-llama'
```

### Stale `node_modules` on the Mac

The Mac's `pnpm install` state is independent of yours. If a freshly
added native dependency fails to resolve:

```bash
ssh <your-ssh-alias> 'cd <path-to-repo-on-mac>/dvai-edge && pnpm install'
```

### CI runner gone offline

Self-hosted runners go offline if the Mac sleeps. Disable App Nap and
"Put hard disks to sleep when possible" in System Settings → Energy.
For headless boxes, configure the Mac to wake-on-LAN and stay awake on
power.

## Privacy hardening

- `scripts/mac.local.json` is gitignored. Never commit it.
- `mac-build.ps1` reads from the local file or env vars; the script
  itself contains no real hostnames, IPs, or paths.
- Workflow YAMLs reference only the generic `[self-hosted, macOS, ARM64]`
  label set.
- The self-hosted runner registration token is single-use (~1 hour TTL).
  Even if leaked it cannot register a second runner.

If you find a real Mac identifier in any committed file, treat it as a
bug and open a PR removing it.

## See also

- [Testing](./testing.md) — full layer-by-layer test guide.
- [Handler parity](./handler-parity.md) — why running Swift tests
  remotely matters.

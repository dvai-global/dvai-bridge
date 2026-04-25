# Model distribution

Multi-gigabyte LLM weights cannot ship inside an iOS / Android binary.
The DVAI-Bridge Capacitor stack solves this with a sha256-verified
resumable downloader that caches into per-platform app-data directories.
This page covers the surrounding decisions: where to host weights,
how to compute checksums, what the first-run UX looks like, and what
to do for multi-file (vision) models.

## Where to host

| Host | Pros | Cons |
|---|---|---|
| **HuggingFace LFS** | Free for public repos, ubiquitous, supports gated access via tokens. | Bandwidth-throttled under load; rate-limited per IP; URLs change between revisions if you don't pin. |
| **S3-compatible object storage** (AWS S3, R2, B2, MinIO) | Cheap egress on R2/B2; predictable URLs; signed URLs for private weights. | You pay for storage + egress; you own caching headers. |
| **Custom CDN** (CloudFront, Fastly, BunnyCDN) | Best-in-class throughput; geo-distributed. | Paid. Origin still needs to live somewhere — typically S3 + CDN. |

**Recommendation for first launch:** pin a HuggingFace LFS revision via
the `resolve/<commit-sha>/` URL form. Move to your own bucket when you
hit rate-limit complaints from beta users.

When pinning HF, prefer the `resolve/main/<file>` form over `blob/main/<file>` —
the latter returns an HTML page, not raw bytes.

## Computing sha256

The downloader **requires** a sha256. There is no "trust me" mode. Compute
it once when you publish the file, hard-code the lowercase hex digest in
your app, and ship.

**macOS / Linux:**

```bash
shasum -a 256 llama-3.2-1b.gguf
# Output:
# d3a55…  llama-3.2-1b.gguf
```

**Windows (PowerShell):**

```powershell
(Get-FileHash -Algorithm SHA256 .\llama-3.2-1b.gguf).Hash.ToLower()
# d3a55…
```

**Node.js (CI script):**

```js
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";

const h = createHash("sha256");
for await (const chunk of createReadStream("model.gguf")) h.update(chunk);
console.log(h.digest("hex"));
```

If the digest mismatches at download-time, the helper deletes the partial
+ destination files and throws — retry-friendly, no half-bad cache to
clean up manually.

## First-run UX

The first download dominates first-launch time-to-value for any local-AI
app. Three things matter:

1. **Show progress, with bytes and percentage.** A multi-GB download
   without feedback feels broken even when it isn't.
2. **Allow cancel.** Killing the process during download is fine — the
   `.partial` file is left in place and the next attempt resumes via
   HTTP `Range`.
3. **Resume on app restart.** No extra code needed: `downloadModel()`
   re-checks the existing `.partial` size and skips ahead.

```ts
import { DVAIBridge, type ProgressEvent } from "@dvai-bridge/capacitor";

let cancelled = false;
const sub = await DVAIBridge.addProgressListener((e: ProgressEvent) => {
  if (cancelled) return;
  if (e.phase === "loading" && e.bytesReceived != null && e.bytesTotal != null) {
    setProgress({
      bytes: e.bytesReceived,
      total: e.bytesTotal,
      percent: e.percent ?? 0,
    });
  } else if (e.phase === "ready") {
    setProgress({ percent: 100 });
  } else if (e.phase === "error") {
    setError(e.message ?? "Download failed");
  }
});

try {
  const { path, cached } = await DVAIBridge.downloadModel({
    url: GGUF_URL,
    sha256: GGUF_SHA256,
    destFilename: "llama-3.2-1b.gguf",
  });
  if (cached) console.log("Reused cached weight at", path);
} finally {
  await sub.remove();
}
```

Progress events are throttled to ~10/sec to avoid pegging the JS thread
on a fast wifi link.

## Bundling small models in `public/`

For models small enough to ship inside the app bundle, you can drop them
in `public/models/<file>` and read the on-device path at runtime.

| Size | Recommendation |
|---|---|
| < 50 MB | Bundle. App-store size hits are negligible. |
| 50–100 MB | Bundle if you control the audience and can update via OTA. Otherwise download. |
| > 100 MB | Download. App stores penalize size, and updating a bundled binary requires a full app-store cycle. |

Reading a bundled file:

```ts
import { Filesystem, Directory } from "@capacitor/filesystem";

const stat = await Filesystem.stat({
  path: "public/models/tiny.gguf",
  directory: Directory.Application, // iOS: bundle; Android: assets
});
await DVAIBridge.start({ backend: "llama", modelPath: stat.uri });
```

Bundle files cannot be `mmap`'d directly on Android — Capacitor copies
them out of the APK on first read. Plan for an extra hundred-MB-scale
copy on first launch if you bundle anything large.

## Multi-file models (GGUF + mmproj)

Vision-capable llama.cpp models ship as a pair: the main GGUF plus a
projection / mmproj file. Both must reach disk before `start()`:

```ts
const { path: gguf } = await DVAIBridge.downloadModel({
  url: GEMMA_GGUF_URL,
  sha256: GEMMA_GGUF_SHA256,
  destFilename: "gemma-4-e2b.gguf",
});
const { path: mmproj } = await DVAIBridge.downloadModel({
  url: GEMMA_MMPROJ_URL,
  sha256: GEMMA_MMPROJ_SHA256,
  destFilename: "gemma-4-e2b-mmproj.gguf",
});

await DVAIBridge.start({
  backend: "llama",
  modelPath: gguf,
  mmprojPath: mmproj,
  contextSize: 4096,
});
```

Track aggregate progress by adding both files' `bytesTotal` ahead of time
and summing `bytesReceived` across the two phases. The default progress
listener fires for whichever download is currently active.

MediaPipe `.task` artifacts are single files; no pairing needed.

## Auth for gated HuggingFace repos

Pass an `Authorization` header in `DownloadOptions.headers`:

```ts
await DVAIBridge.downloadModel({
  url: "https://huggingface.co/<org>/<gated-repo>/resolve/main/model.gguf",
  sha256: "...",
  headers: { Authorization: `Bearer ${hfToken}` },
});
```

Where `hfToken` should be a **read-only** fine-grained token scoped to
the specific repo. Never embed your personal access token in app code —
fetch it from your own backend at runtime, ideally exchanged from the
user's account, and treat its compromise as inevitable.

## Disk-space pre-checks

Use Capacitor's `Filesystem` plugin to query free space before kicking
off a multi-GB download:

```ts
import { Filesystem, Directory } from "@capacitor/filesystem";

const cacheDir = await DVAIBridge.cacheDir();
// On iOS this resolves under <App Support>/<bundle-id>/dvai-models.
// On Android, <filesDir>/dvai-models.

// Capacitor 6+: Filesystem.getFreeDiskSpace()
const { free } = await Filesystem.getFreeDiskSpace?.();
const required = EXPECTED_BYTES * 1.2; // 20% headroom for partial + temp.
if (free != null && free < required) {
  showFreeSpaceWarning({ free, required });
  return;
}
```

If `getFreeDiskSpace` isn't available in your Capacitor version, you can
fall back to a `statvfs`-style native shim or just attempt the download
and surface the platform's `ENOSPC` / disk-full error.

## Cache management

Three helpers cover the cache surface area; everything else is your
policy:

```ts
await DVAIBridge.listCachedModels();
// [{ filename, path, bytes, sha256 }, …]

await DVAIBridge.deleteCachedModel("gemma-4-e2b.gguf");

const dir = await DVAIBridge.cacheDir();
```

There is **no auto-eviction**. If the user installs three 4 GB models
their device will fill up. Provide an in-app "manage downloaded models"
UI that lists `listCachedModels()` and lets the user prune.

## Privacy posture

Local inference keeps user prompts and outputs on-device. Distribution
introduces a single outbound disclosure: the **model URL** itself.

- Outbound traffic at download time reveals to the host (HF, S3, your
  CDN) which model the user is fetching, plus the user's IP.
- After download completes, no further outbound traffic is generated by
  the bridge.
- Cached weights live under app-private storage:
  - **iOS** — `<App Support>/<bundle-id>/dvai-models/`, with
    `isExcludedFromBackupKey = true` set per file (so they don't bloat
    iCloud backup or get restored to a different device).
  - **Android** — `<filesDir>/dvai-models/`, automatically backed up
    only if your app opts in via `android:allowBackup`.
- Neither directory is reachable by other apps on the device.

If your app's privacy policy claims "no data leaves the device," remember
that the model-fetch call is data leaving the device — even if the
payload is inert. Document it.

## See also

- [Capacitor quickstart](./quickstart-capacitor.md) — first-run code.
- [Multimodal](./multimodal.md) — content parts requiring vision / audio
  models often involve multi-file downloads.
- [Tested models](./tested-models.md) — curated list with file sizes
  and recommended `contextSize`.

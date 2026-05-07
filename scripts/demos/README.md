# Demo recording scripts

This directory holds **demo scene descriptors** consumed by
[`scripts/record-demo.sh`](../record-demo.sh) (Bash, macOS / Linux) and
[`scripts/record-demo.ps1`](../record-demo.ps1) (PowerShell, Windows).
Each YAML file describes a single quickstart flow as a fixed-duration
sequence of scenes; the recorder wraps `ffmpeg` to capture the screen
for `sum(durations)` seconds and writes the resulting MP4 to
`docs/marketing/assets/`.

## What the recorder is, and is not

**The recorder is** an `ffmpeg` wrapper. Given a YAML descriptor, it:

- Validates that `ffmpeg` (or `ffmpeg.exe`) is on `PATH`.
- Parses the YAML (uses `yq` if installed, falls back to a flat shell
  parser since the schema is intentionally flat).
- Prints the full scene timeline.
- Calls `ffmpeg` with a platform-appropriate screen-capture input:
  `avfoundation` on macOS, `x11grab` on Linux, `gdigrab` on Windows.
- Writes a single MP4 of length `sum(scene.duration)`.

**The recorder is not** an end-to-end demo automation tool. It does not:

- Launch the example app being demoed.
- Click any UI / drive any input.
- Edit, trim, splice, add captions, or post-process the captured video.

The operator (the human running the recorder) is responsible for:

1. Starting the example app and arranging the visible window before
   running the recorder.
2. Performing the on-screen actions described in each scene's `caption`,
   pacing themselves against the printed timeline.
3. Any post-processing they want — overlay captions, add a soundtrack,
   trim leading/trailing slack, etc.

This split is intentional. Faking automation across seven SDK examples
(React, Capacitor, iOS Simulator, Android emulator, RN, Flutter, MAUI)
would be more code than the rest of the project; the recorder stays
small by being honest about what it is.

## Schema reference

YAML files in this directory are flat and use the following keys:

| Field         | Type   | Required | Description                                                                |
| ------------- | ------ | :------: | -------------------------------------------------------------------------- |
| `name`        | string |    yes   | Slug used in log output. Match the file basename for ease of grep.         |
| `description` | string |    no    | One-line summary printed at the top of the log.                            |
| `output`      | string |    yes   | Path to the MP4 to write. Conventionally `docs/marketing/assets/<sdk>.mp4`. |
| `fps`         | int    |    no    | Frame rate passed to `ffmpeg -framerate`. Default `30`.                    |
| `scenes`      | list   |    yes   | List of `{duration, caption}` items. At least one scene is required.       |
| `scenes[].duration` | int (seconds) | yes | Positive integer. Summed to get total recording length.            |
| `scenes[].caption`  | string        | yes | What the operator should do during this scene. Printed in the timeline. |

Realistic durations are 5–15 seconds per scene; a typical quickstart
demo has 3–5 scenes for a total of 30–60 seconds.

### Example

```yaml
name: web-react-quickstart
description: Hello-world flow on the React example app.
output: docs/marketing/assets/web-quickstart.mp4
fps: 30
scenes:
  - duration: 5
    caption: "Open the app in the browser."
  - duration: 12
    caption: "Watch the model download progress bar."
  - duration: 10
    caption: "Type a prompt; tokens stream in via SSE."
```

## Adding a new flow

1. Copy the closest existing YAML in this directory and rename it.
2. Update `name`, `description`, `output`, and the `scenes` list.
3. Dry-run it:
   ```bash
   bash scripts/record-demo.sh scripts/demos/<your-flow>.yaml --dry-run
   ```
   You should see the parsed scene list and a total duration. The script
   exits 0 even when `ffmpeg` is not installed, because `--dry-run`
   never invokes `ffmpeg`.
4. When the timeline looks right, start the demo app, switch back to the
   terminal, and run the recorder without `--dry-run`. The recorder
   waits 3 seconds before starting `ffmpeg`, so you have time to bring
   the demo window to the front.

## Running the recorder

### macOS / Linux

```bash
# Dry-run (parse + print, no ffmpeg).
bash scripts/record-demo.sh scripts/demos/web-react.yaml --dry-run

# Real recording.
bash scripts/record-demo.sh scripts/demos/web-react.yaml
```

On macOS, `ffmpeg` uses the `avfoundation` input (`1:` = the primary
screen, no audio). On Linux it uses `x11grab` against `$DISPLAY`. Both
can be overridden by exporting `DVAI_RECORD_INPUT` before running.

### Windows

```powershell
# Dry-run.
pwsh -File scripts/record-demo.ps1 scripts/demos/web-react.yaml -DryRun

# Real recording.
pwsh -File scripts/record-demo.ps1 scripts/demos/web-react.yaml
```

The PowerShell wrapper uses `gdigrab` to capture the entire desktop. To
capture a specific window, set `$env:DVAI_RECORD_INPUT = 'title=My App'`
before running.

## Output location

`docs/marketing/assets/` is **gitignored** (see the repo's `.gitignore`
under "Marketing scripts + blog drafts — private"). The recorded MP4s
stay local to the operator's machine until they're explicitly published
elsewhere (a launch announcement, a docs site, etc.).

## Files in this directory

| File                    | Demo                                                |
| ----------------------- | --------------------------------------------------- |
| `web-react.yaml`        | `examples/web-react/` quickstart                    |
| `web-vanilla-cdn.yaml`  | `examples/web-vanilla-cdn/` zero-build quickstart   |
| `node-llama-cpp.yaml`   | `examples/node-llama-cpp/` native backend quickstart |
| `capacitor.yaml`        | Capacitor hybrid mobile quickstart                  |
| `ios-native.yaml`       | `@dvai-bridge/ios` SwiftUI quickstart               |
| `android-native.yaml`   | `co.deepvoiceai:dvai-bridge` Compose quickstart     |
| `react-native.yaml`     | `@dvai-bridge/react-native` TurboModule quickstart  |
| `flutter.yaml`          | `dvai_bridge` Flutter quickstart                    |
| `dotnet-maui.yaml`      | `DVAIBridge` NuGet MAUI / desktop quickstart        |

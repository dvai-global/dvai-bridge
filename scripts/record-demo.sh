#!/usr/bin/env bash
# record-demo.sh — wrap ffmpeg around a flat YAML scene file to record a
# fixed-duration screen capture for a marketing demo.
#
# Usage:
#   bash scripts/record-demo.sh <demo-yaml-path> [--dry-run]
#
# What this DOES:
#   - Parses a flat YAML descriptor (yq if available; grep+awk fallback).
#   - Sums scene durations to get the total recording length.
#   - Calls ffmpeg with a platform-appropriate screen-capture input.
#
# What this DOES NOT do:
#   - Launch the example app being demoed.
#   - Click any UI / drive any input.
#   - Edit, trim, or post-process the captured video.
#
# The user is expected to:
#   1. Start the example app and arrange the visible window.
#   2. Run this script.
#   3. Perform the on-screen actions described in each scene's `caption`,
#      pacing themselves against the printed scene timeline.
#
# Schema (see scripts/demos/README.md):
#   name: <slug>
#   description: <one-line summary>
#   output: <path/to/output.mp4>
#   fps: <integer>
#   scenes:
#     - duration: <seconds>
#       caption: "<what the operator should be doing>"
#     - ...

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
YAML_PATH=""

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME <demo-yaml-path> [--dry-run]

  <demo-yaml-path>   Path to a YAML scene file under scripts/demos/.
  --dry-run          Print the parsed scene list and exit without recording.
EOF
}

# --- Argument parsing ---
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "$SCRIPT_NAME: unknown flag: $arg" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$YAML_PATH" ]]; then
        YAML_PATH="$arg"
      else
        echo "$SCRIPT_NAME: unexpected positional argument: $arg" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

if [[ -z "$YAML_PATH" ]]; then
  echo "$SCRIPT_NAME: missing <demo-yaml-path>." >&2
  usage >&2
  exit 2
fi

if [[ ! -f "$YAML_PATH" ]]; then
  echo "$SCRIPT_NAME: file not found: $YAML_PATH" >&2
  exit 2
fi

# --- Preflight: ffmpeg ---
if ! command -v ffmpeg >/dev/null 2>&1; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "warning: ffmpeg not found on PATH; --dry-run can still parse the YAML." >&2
  else
    echo "$SCRIPT_NAME: ffmpeg not found on PATH." >&2
    echo "  macOS:    brew install ffmpeg" >&2
    echo "  Debian:   sudo apt-get install ffmpeg" >&2
    exit 3
  fi
fi

# --- YAML parsing ---
# Prefer yq when available; otherwise fall back to a flat grep+awk parser
# since the schema is intentionally flat.

NAME=""
DESCRIPTION=""
OUTPUT=""
FPS=""
# Parallel arrays of scene durations + captions.
SCENE_DURATIONS=()
SCENE_CAPTIONS=()

parse_with_yq() {
  NAME="$(yq -r '.name // ""' "$YAML_PATH")"
  DESCRIPTION="$(yq -r '.description // ""' "$YAML_PATH")"
  OUTPUT="$(yq -r '.output // ""' "$YAML_PATH")"
  FPS="$(yq -r '.fps // 30' "$YAML_PATH")"

  local count
  count="$(yq -r '.scenes | length' "$YAML_PATH")"
  local i=0
  while [[ "$i" -lt "$count" ]]; do
    SCENE_DURATIONS+=("$(yq -r ".scenes[$i].duration" "$YAML_PATH")")
    SCENE_CAPTIONS+=("$(yq -r ".scenes[$i].caption" "$YAML_PATH")")
    i=$((i + 1))
  done
}

parse_with_awk() {
  # Top-level scalars: any line shaped `key: value` BEFORE the `scenes:` key.
  # Inside `scenes:`, list items are indented; each item begins with `- `.

  local in_scenes=0
  local cur_dur=""
  local cur_cap=""

  # Helper: trim leading/trailing whitespace and strip surrounding quotes.
  trim_strip() {
    local s="$1"
    # Trim leading whitespace.
    s="${s#"${s%%[![:space:]]*}"}"
    # Trim trailing whitespace.
    s="${s%"${s##*[![:space:]]}"}"
    # Strip surrounding double or single quotes if symmetric.
    if [[ "${s:0:1}" == '"' && "${s: -1}" == '"' ]]; then
      s="${s:1:${#s}-2}"
    elif [[ "${s:0:1}" == "'" && "${s: -1}" == "'" ]]; then
      s="${s:1:${#s}-2}"
    fi
    printf '%s' "$s"
  }

  flush_scene() {
    if [[ -n "$cur_dur" || -n "$cur_cap" ]]; then
      SCENE_DURATIONS+=("${cur_dur:-0}")
      SCENE_CAPTIONS+=("${cur_cap:-}")
      cur_dur=""
      cur_cap=""
    fi
  }

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    # Skip blank or comment-only lines.
    case "$raw_line" in
      ''|\#*) continue ;;
    esac
    # Strip trailing comments — but only when the `#` is preceded by space,
    # so URLs (https://#frag) are preserved if anyone ever uses one.
    local line="$raw_line"
    if [[ "$line" =~ [[:space:]]#.*$ ]]; then
      line="${line%%[[:space:]]#*}"
    fi

    if [[ "$in_scenes" -eq 0 ]]; then
      case "$line" in
        scenes:*)
          in_scenes=1
          continue
          ;;
        name:*)
          NAME="$(trim_strip "${line#name:}")"
          ;;
        description:*)
          DESCRIPTION="$(trim_strip "${line#description:}")"
          ;;
        output:*)
          OUTPUT="$(trim_strip "${line#output:}")"
          ;;
        fps:*)
          FPS="$(trim_strip "${line#fps:}")"
          ;;
      esac
    else
      # Inside scenes: detect `- duration:` (start of a new scene) or
      # an indented `caption:` / `duration:` continuation line.
      local stripped
      stripped="$(trim_strip "$line")"
      case "$stripped" in
        -\ duration:*)
          flush_scene
          cur_dur="$(trim_strip "${stripped#- duration:}")"
          ;;
        -\ caption:*)
          flush_scene
          cur_cap="$(trim_strip "${stripped#- caption:}")"
          ;;
        duration:*)
          cur_dur="$(trim_strip "${stripped#duration:}")"
          ;;
        caption:*)
          cur_cap="$(trim_strip "${stripped#caption:}")"
          ;;
      esac
    fi
  done < "$YAML_PATH"

  flush_scene

  # Defaults.
  if [[ -z "$FPS" ]]; then FPS=30; fi
}

if command -v yq >/dev/null 2>&1; then
  parse_with_yq
else
  parse_with_awk
fi

if [[ -z "$NAME" ]]; then
  echo "$SCRIPT_NAME: 'name' field is missing or empty in $YAML_PATH" >&2
  exit 4
fi
if [[ -z "$OUTPUT" ]]; then
  echo "$SCRIPT_NAME: 'output' field is missing or empty in $YAML_PATH" >&2
  exit 4
fi
if [[ "${#SCENE_DURATIONS[@]}" -eq 0 ]]; then
  echo "$SCRIPT_NAME: no scenes found in $YAML_PATH" >&2
  exit 4
fi

# --- Total duration ---
TOTAL=0
i=0
while [[ "$i" -lt "${#SCENE_DURATIONS[@]}" ]]; do
  d="${SCENE_DURATIONS[$i]}"
  if ! [[ "$d" =~ ^[0-9]+$ ]]; then
    echo "$SCRIPT_NAME: scene $((i + 1)) has non-integer duration: '$d'" >&2
    exit 4
  fi
  TOTAL=$((TOTAL + d))
  i=$((i + 1))
done

# --- Print plan ---
echo "demo:        $NAME"
if [[ -n "$DESCRIPTION" ]]; then
  echo "description: $DESCRIPTION"
fi
echo "output:      $OUTPUT"
echo "fps:         $FPS"
echo "scenes:      ${#SCENE_DURATIONS[@]} (total ${TOTAL}s)"
echo ""

elapsed=0
i=0
while [[ "$i" -lt "${#SCENE_DURATIONS[@]}" ]]; do
  d="${SCENE_DURATIONS[$i]}"
  c="${SCENE_CAPTIONS[$i]}"
  start="$elapsed"
  end=$((elapsed + d))
  printf "  %2d. [%3ds → %3ds] (%2ds) %s\n" "$((i + 1))" "$start" "$end" "$d" "$c"
  elapsed="$end"
  i=$((i + 1))
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo ""
  echo "(dry-run — ffmpeg not invoked.)"
  exit 0
fi

# --- Pick a screen-capture input device ---
# macOS:  avfoundation, "1:" is screen 1, no audio.
# Linux:  x11grab on $DISPLAY.
# Other:  refuse and explain.
INPUT_FORMAT=""
INPUT_SOURCE=""
case "$(uname -s)" in
  Darwin)
    INPUT_FORMAT="avfoundation"
    INPUT_SOURCE="${DVAI_RECORD_INPUT:-1:}"
    ;;
  Linux)
    INPUT_FORMAT="x11grab"
    INPUT_SOURCE="${DVAI_RECORD_INPUT:-${DISPLAY:-:0.0}}"
    ;;
  *)
    echo "$SCRIPT_NAME: unsupported OS '$(uname -s)' for live recording." >&2
    echo "  Use scripts/record-demo.ps1 on Windows." >&2
    exit 5
    ;;
esac

# --- Ensure output directory exists ---
out_dir="$(dirname "$OUTPUT")"
mkdir -p "$out_dir"

echo ""
echo "Recording for ${TOTAL}s via ffmpeg ($INPUT_FORMAT $INPUT_SOURCE) → $OUTPUT"
echo "Bring the demo window to the front NOW. Recording starts in 3s..."
sleep 3

ffmpeg -y \
  -f "$INPUT_FORMAT" \
  -framerate "$FPS" \
  -i "$INPUT_SOURCE" \
  -t "$TOTAL" \
  -c:v libx264 \
  -preset veryfast \
  -pix_fmt yuv420p \
  "$OUTPUT"

echo ""
echo "Wrote $OUTPUT (${TOTAL}s)."

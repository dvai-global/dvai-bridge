#!/usr/bin/env bash
# build-all.sh — Run every per-platform build script that can run on this host.
#
# Auto-detects host (Mac vs. Linux vs. Windows-bash) and runs only the
# slices that work there. Per-slice failures don't abort the run by
# default; final summary tells you which slices passed / failed.
#
# Flags:
#   --fail-fast   abort on first per-slice failure (CI usage).
#
# Exit code: 0 if all attempted slices passed; 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FAIL_FAST=false
for arg in "$@"; do
    case "$arg" in
        --fail-fast) FAIL_FAST=true ;;
        --help|-h)
            sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

HOST="$(uname -s)"
echo "==> Host: $HOST"
echo

declare -a SLICES_RUN
declare -a SLICES_OK
declare -a SLICES_FAILED
declare -a SLICES_SKIPPED
declare -A SLICE_DURATION

run_slice() {
    local slice="$1"
    local script="scripts/build-$slice.sh"

    if [[ ! -x "$script" ]]; then
        # Maybe just not chmod+x'd yet — try via bash explicitly.
        script="bash $script"
    fi

    echo "================================================================"
    echo "==> Slice: $slice"
    echo "================================================================"

    SLICES_RUN+=("$slice")
    local start_ts
    start_ts="$(date +%s)"

    if eval "$script"; then
        local end_ts
        end_ts="$(date +%s)"
        SLICE_DURATION[$slice]=$((end_ts - start_ts))
        SLICES_OK+=("$slice")
        echo "==> $slice: OK (${SLICE_DURATION[$slice]}s)"
    else
        local end_ts
        end_ts="$(date +%s)"
        SLICE_DURATION[$slice]=$((end_ts - start_ts))
        SLICES_FAILED+=("$slice")
        echo "==> $slice: FAILED (${SLICE_DURATION[$slice]}s)"
        if $FAIL_FAST; then
            echo "==> --fail-fast set; aborting." >&2
            print_summary
            exit 1
        fi
    fi
    echo
}

skip_slice() {
    local slice="$1"
    local reason="$2"
    SLICES_SKIPPED+=("$slice ($reason)")
    echo "==> Slice: $slice — SKIPPED: $reason"
    echo
}

print_summary() {
    echo
    echo "================================================================"
    echo "Build summary"
    echo "================================================================"
    for s in "${SLICES_OK[@]:-}"; do
        printf "  %-15s ✅ %ss\n" "$s" "${SLICE_DURATION[$s]:-?}"
    done
    for s in "${SLICES_FAILED[@]:-}"; do
        printf "  %-15s ❌ %ss\n" "$s" "${SLICE_DURATION[$s]:-?}"
    done
    for s in "${SLICES_SKIPPED[@]:-}"; do
        printf "  %-15s ⊘  %s\n" "${s%% *}" "${s#* }"
    done
    echo "----------------------------------------------------------------"
    local total_ok=${#SLICES_OK[@]}
    local total_failed=${#SLICES_FAILED[@]}
    local total_run=${#SLICES_RUN[@]}
    echo "Total: $total_ok/$total_run slices green; $total_failed failed; ${#SLICES_SKIPPED[@]} skipped."
}

# Web — runs everywhere.
run_slice web

# iOS — Mac only.
if [[ "$HOST" == "Darwin" ]]; then
    run_slice ios
else
    skip_slice ios "Mac-only (use scripts/mac-build.ps1 for SSH-attached Mac)"
fi

# Android — needs JDK + Android SDK. Try; if missing, skip.
if [[ -n "${JAVA_HOME:-}" && -n "${ANDROID_HOME:-}" ]]; then
    run_slice android
else
    skip_slice android "needs JAVA_HOME + ANDROID_HOME"
fi

# React Native — runs anywhere; example app builds are host-conditional inside the script.
run_slice react-native

# Flutter — needs flutter SDK.
if command -v flutter >/dev/null 2>&1; then
    run_slice flutter
else
    skip_slice flutter "flutter SDK not on PATH"
fi

# .NET — needs dotnet 10+.
if command -v dotnet >/dev/null 2>&1; then
    run_slice dotnet
else
    skip_slice dotnet "dotnet not on PATH"
fi

print_summary

if [[ ${#SLICES_FAILED[@]} -gt 0 ]]; then
    exit 1
fi
exit 0

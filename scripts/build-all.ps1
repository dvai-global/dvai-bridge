# build-all.ps1 — Windows mirror of build-all.sh.
#
# Strategy:
#   - If WSL is detected, defer to `wsl bash scripts/build-all.sh` for the
#     full matrix (preferred — keeps the bash scripts as the single source
#     of truth).
#   - Otherwise, run the Windows-supported subset (.NET + Web + Android)
#     directly via PowerShell.
#
# Flags:
#   -FailFast  abort on first per-slice failure.

param(
    [switch]$FailFast = $false
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path
Set-Location $RepoRoot

# Prefer WSL if available — full matrix.
$wsl = Get-Command wsl -ErrorAction SilentlyContinue
if ($wsl) {
    Write-Host "==> WSL detected; deferring to bash scripts/build-all.sh for full matrix" -ForegroundColor Cyan
    $args = if ($FailFast) { "--fail-fast" } else { "" }
    & wsl bash "scripts/build-all.sh" $args
    exit $LASTEXITCODE
}

Write-Host "==> No WSL; running Windows-supported subset (.NET + Web + Android)" -ForegroundColor Cyan
Write-Host ""

$slicesOK = @()
$slicesFailed = @()
$slicesSkipped = @()

function Run-Slice {
    param([string]$Name, [string]$Script)

    Write-Host "================================================================"
    Write-Host "==> Slice: $Name"
    Write-Host "================================================================"

    $start = Get-Date
    try {
        bash $Script
        if ($LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
        $duration = ((Get-Date) - $start).TotalSeconds
        $script:slicesOK += [PSCustomObject]@{ Name = $Name; Duration = [math]::Round($duration, 1) }
        Write-Host "==> ${Name}: OK ($([math]::Round($duration, 1))s)" -ForegroundColor Green
    } catch {
        $duration = ((Get-Date) - $start).TotalSeconds
        $script:slicesFailed += [PSCustomObject]@{ Name = $Name; Duration = [math]::Round($duration, 1) }
        Write-Host "==> ${Name}: FAILED ($([math]::Round($duration, 1))s)" -ForegroundColor Red
        if ($FailFast) { throw }
    }
    Write-Host ""
}

function Skip-Slice {
    param([string]$Name, [string]$Reason)
    $script:slicesSkipped += [PSCustomObject]@{ Name = $Name; Reason = $Reason }
    Write-Host "==> Slice: $Name — SKIPPED: $Reason" -ForegroundColor Yellow
    Write-Host ""
}

# Web
Run-Slice "web" "scripts/build-web.sh"

# iOS — never on Windows.
Skip-Slice "ios" "Mac-only; use scripts/mac-build.ps1 for SSH-attached Mac"

# Android — needs JDK + ANDROID_HOME.
if ($env:JAVA_HOME -and $env:ANDROID_HOME) {
    Run-Slice "android" "scripts/build-android.sh"
} else {
    Skip-Slice "android" "needs JAVA_HOME + ANDROID_HOME"
}

# React Native
Run-Slice "react-native" "scripts/build-react-native.sh"

# Flutter
if (Get-Command flutter -ErrorAction SilentlyContinue) {
    Run-Slice "flutter" "scripts/build-flutter.sh"
} else {
    Skip-Slice "flutter" "flutter SDK not on PATH"
}

# .NET
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    Run-Slice "dotnet" "scripts/build-dotnet.sh"
} else {
    Skip-Slice "dotnet" "dotnet not on PATH"
}

# Summary
Write-Host ""
Write-Host "================================================================"
Write-Host "Build summary"
Write-Host "================================================================"
foreach ($s in $slicesOK) { Write-Host ("  {0,-15} OK   {1}s" -f $s.Name, $s.Duration) -ForegroundColor Green }
foreach ($s in $slicesFailed) { Write-Host ("  {0,-15} FAIL {1}s" -f $s.Name, $s.Duration) -ForegroundColor Red }
foreach ($s in $slicesSkipped) { Write-Host ("  {0,-15} SKIP {1}" -f $s.Name, $s.Reason) -ForegroundColor Yellow }
Write-Host "----------------------------------------------------------------"
Write-Host "Total: $($slicesOK.Count)/$($slicesOK.Count + $slicesFailed.Count) slices green; $($slicesFailed.Count) failed; $($slicesSkipped.Count) skipped."

if ($slicesFailed.Count -gt 0) { exit 1 } else { exit 0 }

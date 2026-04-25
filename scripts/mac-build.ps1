#!/usr/bin/env pwsh
# scripts/mac-build.ps1 — Windows-side launcher for Mac-remote builds.
# Reads connection details from scripts/mac.local.json (gitignored) or env vars.
param(
    [Parameter(Mandatory=$true)] [ValidateSet("build","test","clean")] [string]$Action,
    [Parameter(Mandatory=$true)] [string]$Target,
    [string]$Filter = ""
)

$ErrorActionPreference = "Stop"

$configPath = Join-Path $PSScriptRoot "mac.local.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath | ConvertFrom-Json
    $sshAlias = $config.sshAlias
    $repoPath = $config.repoPath
} else {
    $sshAlias = $env:DVAI_MAC_SSH_ALIAS
    $repoPath = $env:DVAI_MAC_REPO_PATH
}

if (-not $sshAlias) { throw "Missing SSH alias. Create scripts/mac.local.json or set DVAI_MAC_SSH_ALIAS." }
if (-not $repoPath) { throw "Missing repo path. Create scripts/mac.local.json or set DVAI_MAC_REPO_PATH." }

$scriptName = "mac-side-$Action.sh"
Write-Host "[mac-build] $Action --> $Target on $sshAlias..." -ForegroundColor Cyan

$cmd = "cd '$repoPath' && git pull --ff-only && bash scripts/$scriptName '$Target' '$Filter'"
ssh $sshAlias $cmd
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Host "[mac-build] FAILED with exit code $exitCode" -ForegroundColor Red
    exit $exitCode
}
Write-Host "[mac-build] OK" -ForegroundColor Green

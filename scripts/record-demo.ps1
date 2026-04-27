<#
.SYNOPSIS
  Record a fixed-duration screen capture for a marketing demo on Windows.

.DESCRIPTION
  Wraps ffmpeg.exe around a flat YAML scene file. Parses the YAML with a
  small line-based parser (the schema is intentionally flat — top-level
  scalars + a `scenes:` list of `{duration, caption}`). Sums scene
  durations to get the total recording length, then captures the desktop
  with ffmpeg's `gdigrab` input.

  This script does NOT:
    - Launch the example app being demoed.
    - Click any UI / drive any input.
    - Edit, trim, or post-process the captured video.

  The user is expected to:
    1. Start the example app and bring its window to the front.
    2. Run this script.
    3. Perform the on-screen actions described in each scene's caption,
       pacing themselves against the printed scene timeline.

.PARAMETER YamlPath
  Path to a YAML scene file under scripts/demos/.

.PARAMETER DryRun
  Print the parsed scene list and exit without recording.

.EXAMPLE
  pwsh -File scripts/record-demo.ps1 scripts/demos/web-react.yaml -DryRun

.EXAMPLE
  pwsh -File scripts/record-demo.ps1 scripts/demos/dotnet-maui.yaml
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$YamlPath,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $YamlPath)) {
    Write-Error "record-demo.ps1: file not found: $YamlPath"
    exit 2
}

# --- Preflight: ffmpeg ---
$ffmpeg = Get-Command -Name 'ffmpeg.exe' -ErrorAction SilentlyContinue
if ($null -eq $ffmpeg) {
    if ($DryRun) {
        Write-Warning "ffmpeg.exe not found on PATH; --DryRun can still parse the YAML."
    } else {
        Write-Error @"
record-demo.ps1: ffmpeg.exe not found on PATH.
  winget install Gyan.FFmpeg
  choco install ffmpeg
  scoop install ffmpeg
"@
        exit 3
    }
}

# --- YAML parsing (flat) ---
function Trim-Strip {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $s = $Value.Trim()
    if ($s.Length -ge 2) {
        $first = $s[0]
        $last = $s[$s.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or
            ($first -eq "'" -and $last -eq "'")) {
            $s = $s.Substring(1, $s.Length - 2)
        }
    }
    return $s
}

$name = ''
$description = ''
$output = ''
$fps = 30
$scenes = New-Object System.Collections.Generic.List[object]

$inScenes = $false
$curDur = $null
$curCap = $null

function Flush-Scene {
    if ($null -ne $script:curDur -or $null -ne $script:curCap) {
        $script:scenes.Add([pscustomobject]@{
            Duration = if ($null -ne $script:curDur) { [int]$script:curDur } else { 0 }
            Caption  = if ($null -ne $script:curCap) { [string]$script:curCap } else { '' }
        }) | Out-Null
        $script:curDur = $null
        $script:curCap = $null
    }
}

foreach ($rawLine in Get-Content -LiteralPath $YamlPath) {
    $line = $rawLine
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $trimmed = $line.TrimStart()
    if ($trimmed.StartsWith('#')) { continue }

    # Strip trailing comment when '#' is preceded by whitespace.
    $hashIdx = -1
    for ($i = 0; $i -lt $line.Length; $i++) {
        if ($line[$i] -eq '#' -and $i -gt 0 -and [char]::IsWhiteSpace($line[$i - 1])) {
            $hashIdx = $i; break
        }
    }
    if ($hashIdx -ge 0) { $line = $line.Substring(0, $hashIdx) }

    if (-not $inScenes) {
        if ($line -match '^\s*scenes\s*:\s*$') {
            $inScenes = $true
            continue
        }
        if ($line -match '^\s*name\s*:\s*(.*)$') {
            $name = Trim-Strip $matches[1]
        } elseif ($line -match '^\s*description\s*:\s*(.*)$') {
            $description = Trim-Strip $matches[1]
        } elseif ($line -match '^\s*output\s*:\s*(.*)$') {
            $output = Trim-Strip $matches[1]
        } elseif ($line -match '^\s*fps\s*:\s*(.*)$') {
            $fpsRaw = Trim-Strip $matches[1]
            if ($fpsRaw -match '^\d+$') { $fps = [int]$fpsRaw }
        }
    } else {
        $stripped = (Trim-Strip $line)

        if ($stripped -match '^-\s*duration\s*:\s*(.*)$') {
            Flush-Scene
            $curDur = (Trim-Strip $matches[1])
        } elseif ($stripped -match '^-\s*caption\s*:\s*(.*)$') {
            Flush-Scene
            $curCap = (Trim-Strip $matches[1])
        } elseif ($stripped -match '^duration\s*:\s*(.*)$') {
            $curDur = (Trim-Strip $matches[1])
        } elseif ($stripped -match '^caption\s*:\s*(.*)$') {
            $curCap = (Trim-Strip $matches[1])
        }
    }
}
Flush-Scene

if ([string]::IsNullOrEmpty($name)) {
    Write-Error "record-demo.ps1: 'name' field is missing or empty in $YamlPath"
    exit 4
}
if ([string]::IsNullOrEmpty($output)) {
    Write-Error "record-demo.ps1: 'output' field is missing or empty in $YamlPath"
    exit 4
}
if ($scenes.Count -eq 0) {
    Write-Error "record-demo.ps1: no scenes found in $YamlPath"
    exit 4
}

$total = 0
foreach ($s in $scenes) {
    if ($s.Duration -le 0) {
        Write-Error "record-demo.ps1: scene with non-positive duration: $($s.Duration)"
        exit 4
    }
    $total += $s.Duration
}

# --- Print plan ---
Write-Host "demo:        $name"
if ($description) { Write-Host "description: $description" }
Write-Host "output:      $output"
Write-Host "fps:         $fps"
Write-Host "scenes:      $($scenes.Count) (total ${total}s)"
Write-Host ""

$elapsed = 0
for ($i = 0; $i -lt $scenes.Count; $i++) {
    $d = $scenes[$i].Duration
    $c = $scenes[$i].Caption
    $start = $elapsed
    $end = $elapsed + $d
    Write-Host ("  {0,2}. [{1,3}s -> {2,3}s] ({3,2}s) {4}" -f ($i + 1), $start, $end, $d, $c)
    $elapsed = $end
}

if ($DryRun) {
    Write-Host ""
    Write-Host "(dry-run -- ffmpeg not invoked.)"
    exit 0
}

# --- Ensure output directory exists ---
$outDir = Split-Path -Parent $output
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

Write-Host ""
Write-Host "Recording for ${total}s via ffmpeg.exe (gdigrab desktop) -> $output"
Write-Host "Bring the demo window to the front NOW. Recording starts in 3s..."
Start-Sleep -Seconds 3

# gdigrab captures the entire desktop. Override via $env:DVAI_RECORD_INPUT
# (e.g. "title=My App Window") to capture a specific window.
$inputSource = if ($env:DVAI_RECORD_INPUT) { $env:DVAI_RECORD_INPUT } else { 'desktop' }

& 'ffmpeg.exe' `
    -y `
    -f gdigrab `
    -framerate $fps `
    -i $inputSource `
    -t $total `
    -c:v libx264 `
    -preset veryfast `
    -pix_fmt yuv420p `
    $output

if ($LASTEXITCODE -ne 0) {
    Write-Error "ffmpeg.exe exited with code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Wrote $output (${total}s)."

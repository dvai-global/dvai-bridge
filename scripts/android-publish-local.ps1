# scripts/android-publish-local.ps1 — Windows companion to android-publish-local.sh.
#
# Publishes every Android module in the monorepo to ~/.m2/repository
# (mavenLocal) in dependency order so the example apps under
# `examples/android-*/` and any consumer app can resolve
# `co.deepvoiceai:dvai-bridge:<version>` (and the four `*-core` artifacts)
# from a local Maven repo without round-tripping through GitHub Packages.
#
# Order matters:
#   1. android-shared-core      (foundation; depends on nothing)
#   2. android-llama-core       (depends on shared-core)
#      android-mediapipe-core   (depends on shared-core)
#      android-litert-core      (depends on shared-core)
#   3. dvai-bridge-android      (depends on all of the above)
#
# Required env (set automatically if Android Studio is at the default
# location; override on machines where it is installed elsewhere):
#   JAVA_HOME    — JDK 21+ (Robolectric @ compileSdk 36)
#   ANDROID_HOME — Android SDK with platforms 35 and build-tools
#
# AGP 9.2.0 has a Windows-only `parseLocalResources` parser bug against
# android-36's `public-final.xml`; this script forwards
# `-PcompileSdkOverride=35` so the publish runs cleanly on Windows. On
# Mac/Linux the override is harmless (also resolves to 35) — the platform
# bug only manifests in the AGP/Windows pairing.

$ErrorActionPreference = "Stop"

if (-not $env:JAVA_HOME) {
    $studioJbr = "C:\Program Files\Android\Android Studio\jbr"
    if (Test-Path "$studioJbr\bin\java.exe") {
        $env:JAVA_HOME = $studioJbr
    } else {
        Write-Error "JAVA_HOME unset. Install Android Studio (its bundled JBR ships JDK 21+) or set JAVA_HOME manually."
    }
}
if (-not $env:ANDROID_HOME) {
    $defaultSdk = "$env:LOCALAPPDATA\Android\Sdk"
    if (Test-Path $defaultSdk) {
        $env:ANDROID_HOME = $defaultSdk
    } else {
        Write-Error "ANDROID_HOME unset and $defaultSdk not found. Set ANDROID_HOME and re-run."
    }
}

Write-Host "[android-publish-local] JAVA_HOME    = $env:JAVA_HOME"
Write-Host "[android-publish-local] ANDROID_HOME = $env:ANDROID_HOME"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$packages = @(
    "dvai-bridge-android-shared-core",
    "dvai-bridge-android-llama-core",
    "dvai-bridge-android-mediapipe-core",
    "dvai-bridge-android-litert-core",
    "dvai-bridge-android"
)

foreach ($pkg in $packages) {
    $pkgDir = Join-Path $repoRoot "packages\$pkg\android"
    if (-not (Test-Path $pkgDir)) {
        Write-Host "[android-publish-local] $pkg not present yet; skipping"
        continue
    }
    Write-Host ""
    Write-Host "===================================================================="
    Write-Host "[android-publish-local] $pkg -> mavenLocal"
    Write-Host "===================================================================="
    Push-Location $pkgDir
    try {
        & .\gradlew.bat publishToMavenLocal -PcompileSdkOverride=35 --console=plain --quiet
        if ($LASTEXITCODE -ne 0) {
            throw "publishToMavenLocal failed for $pkg"
        }
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "[android-publish-local] All packages published. Verify with:"
Write-Host "    Get-ChildItem $env:USERPROFILE\.m2\repository\co\deepvoiceai\"

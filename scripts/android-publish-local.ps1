<#
.SYNOPSIS
Publishes every Android module in the monorepo to ~/.m2/repository (mavenLocal) in dependency order.

.DESCRIPTION
Publishes every Android module in the monorepo to ~/.m2/repository
(mavenLocal) in dependency order so cross-package `implementation
'co.deepvoiceai:android-shared-core:<version>'` style dependencies
resolve cleanly during dev.

Order matters:
  1. android-shared-core      (foundation; depends on nothing)
  2. android-llama-core       (depends on shared-core)
     android-mediapipe-core   (depends on shared-core)
     android-litert-core      (depends on shared-core)         [Phase 3D Task 5+]
  3. dvai-bridge-android      (depends on all of the above)    [Phase 3D Task 10+]

Required env (set automatically if Android Studio is at the default
location; override on machines where it's installed elsewhere):
  JAVA_HOME    — JDK 17+ (Gradle 9.4.x requires it, though Robolectric needs 21+)
  ANDROID_HOME — Android SDK with platforms 36 and build-tools
#>

$ErrorActionPreference = "Stop"

# Resolve paths relative to repo root no matter where the script is invoked from.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

# Best-effort defaults for JAVA_HOME / ANDROID_HOME.
#
# Robolectric @ compileSdk 36 requires **JDK 21+** at test runtime.
if (-not $env:JAVA_HOME) {
    $DefaultJbr = "${env:ProgramFiles}\Android\Android Studio\jbr"
    
    $Picked = ""
    if (Test-Path "$DefaultJbr\bin\java.exe") {
        $Picked = $DefaultJbr
    }
    
    if (-not $Picked) {
        Write-Error "[android-publish-local] JAVA_HOME unset and no JDK found at Android Studio JBR."
        Write-Error "                        Install JDK 21+ and set JAVA_HOME, then re-run."
        exit 1
    }
    $env:JAVA_HOME = $Picked

    # Sanity-check that the picked JDK is at least 21 (Robolectric @ SDK 36 requirement).
    $JavaVersionOutput = & "$env:JAVA_HOME\bin\java.exe" -version 2>&1
    $JavaMajor = $null
    foreach ($line in $JavaVersionOutput) {
        if ($line -match 'version "(\d+)\.') {
            $JavaMajor = [int]$matches[1]
            break
        }
    }
    
    if ($null -ne $JavaMajor -and $JavaMajor -lt 21) {
        Write-Error "[android-publish-local] Picked JDK $JavaMajor at $env:JAVA_HOME, but Robolectric needs 21+."
        Write-Error "                        Install a newer JDK and re-run."
        exit 1
    }
}

if (-not $env:ANDROID_HOME) {
    $DefaultSdk = "$env:LOCALAPPDATA\Android\Sdk"
    if (Test-Path $DefaultSdk) {
        $env:ANDROID_HOME = $DefaultSdk
    } else {
        Write-Error "[android-publish-local] ANDROID_HOME unset and ~/AppData/Local/Android/Sdk not found."
        Write-Error "                        Set ANDROID_HOME to your Android SDK root before re-running."
        exit 1
    }
}

Write-Host "[android-publish-local] JAVA_HOME    = $env:JAVA_HOME"
Write-Host "[android-publish-local] ANDROID_HOME = $env:ANDROID_HOME"

# Each entry: directory under packages/.
$Packages = @(
    "dvai-bridge-android-shared-core",
    "dvai-bridge-android-llama-core",
    "dvai-bridge-android-mediapipe-core",
    "dvai-bridge-android-litert-core",
    "dvai-bridge-android"
)

foreach ($Pkg in $Packages) {
    $PkgDir = "$RepoRoot\packages\$Pkg\android"
    if (-not (Test-Path $PkgDir)) {
        Write-Host "[android-publish-local] $Pkg not present yet; skipping" -ForegroundColor Yellow
        continue
    }
    
    Write-Host "`n===================================================================="
    Write-Host "[android-publish-local] $Pkg -> mavenLocal"
    Write-Host "===================================================================="
    
    Push-Location $PkgDir
    try {
        $GradleArgs = @("publishToMavenLocal", "--console=plain", "--quiet")
        if ($env:COMPILE_SDK_OVERRIDE) {
            $GradleArgs += "-PcompileSdkOverride=$env:COMPILE_SDK_OVERRIDE"
        }
        
        # Call gradlew.bat
        & .\gradlew.bat $GradleArgs
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Gradle build failed with exit code $LASTEXITCODE"
            exit $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }
}

Write-Host "`n[android-publish-local] All packages published. Verify with:"
Write-Host "    dir ~/.m2/repository/co/deepvoiceai/"

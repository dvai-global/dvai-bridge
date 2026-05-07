// Example app settings — Phase 2 Task 3.
//
// Resolution model:
//   * The example pulls `co.deepvoiceai:dvai-bridge` from `mavenLocal()`.
//     Run `pwsh scripts/android-publish-local.ps1` (Windows) or
//     `bash scripts/android-publish-local.sh` (Mac/Linux) once after any
//     SDK source change to refresh `~/.m2/repository`.
//
//   * The umbrella pulls in all four `co.deepvoiceai:android-*-core`
//     artifacts as transitive `api` deps, so the example only needs to
//     declare `dvai-bridge` itself.
//
// Why not Gradle composite-build (`includeBuild`)?
//   * The cores are Groovy `build.gradle` projects with their own
//     `buildscript { classpath ... }` blocks declaring AGP. Including
//     them as composites collides with the consumer's `pluginManagement`
//     and produces "Cannot find a version of com.android.application
//     that satisfies the version constraint" errors. The published-AAR
//     path is the supported developer flow (matches what real consumers
//     of the SDK do via GitHub Packages Maven).

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Phase 2: cores + umbrella resolve here after the publish script runs.
        mavenLocal()
    }
}

rootProject.name = "android-llama"
include(":app")

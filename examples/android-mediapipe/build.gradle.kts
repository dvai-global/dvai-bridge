// Example app root build.gradle.kts — Phase 2 Task 3.
//
// AGP 9.x + Kotlin 2.x. The plugins block declares the versions; the
// `app/build.gradle.kts` `apply false` style keeps the umbrella
// AGP/Kotlin coordination predictable.

plugins {
    id("com.android.application") version "9.2.0" apply false
    // AGP 9.0+ ships built-in Kotlin support; the standalone
    // `org.jetbrains.kotlin.android` plugin is no longer applied (see
    // https://kotl.in/gradle/agp-built-in-kotlin). The Compose Compiler
    // plugin still ships separately and is pinned to match the SDK
    // cores' Kotlin 2.3.21.
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.21" apply false
}

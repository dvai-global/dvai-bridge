// Phase 2 Task 3 — `android-llama` example app.
// Minimal Compose UI driving DVAIBridge.start() with BackendKind.Llama.

import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    // AGP 9.0+ has built-in Kotlin support; we only apply the Compose
    // Compiler plugin on top.
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "co.deepvoiceai.example.llama"
    // Library SDK pin is 36; example apps default to 35 to match the
    // umbrella's `compileSdkOverride` Windows fallback.
    compileSdk = (project.findProperty("compileSdkOverride") as String?)?.toInt() ?: 37
    // Compose BOM 2026.11 needs API 37.1 (minor SDK).
    compileSdkMinor = 1

    defaultConfig {
        applicationId = "co.deepvoiceai.example.llama"
        minSdk = 24
        targetSdk = (project.findProperty("compileSdkOverride") as String?)?.toInt() ?: 37
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    // The umbrella `co.deepvoiceai:dvai-bridge` brings in all four cores
    // (shared/llama/mediapipe/litert) as transitive `api` deps. Resolved
    // from `mavenLocal()` after `pwsh scripts/android-publish-local.ps1`.
    implementation("co.deepvoiceai:dvai-bridge:4.3.0")

    // OkHttp is already pulled in transitively through shared-core, but
    // declaring it here makes the example self-explanatory.
    implementation("com.squareup.okhttp3:okhttp:5.5.1")

    // Compose BOM keeps Material 3 + Foundation versions consistent.
    val composeBom = platform("androidx.compose:compose-bom:2026.11.01")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // Kotlin coroutines + Lifecycle for collectAsState / viewModelScope.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.1")

    // OpenAI Kotlin client — idiomatic per the spec
    // (https://github.com/aallam/openai-kotlin).
    implementation("com.aallam.openai:openai-client:4.2.0")
    // Ktor engine for the OpenAI client. Match the Ktor 3.x family
    // already on the classpath via the shared-core dep.
    implementation("io.ktor:ktor-client-okhttp:3.6.1")

    // Tests
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("com.squareup.okhttp3:okhttp:5.5.1")
}

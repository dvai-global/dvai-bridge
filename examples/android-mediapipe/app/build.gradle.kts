// Phase 2 Task 3 — `android-mediapipe` example app.
// Minimal Compose UI driving DVAIBridge.start() with BackendKind.MediaPipe.

import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "co.deepvoiceai.example.mediapipe"
    compileSdk = (project.findProperty("compileSdkOverride") as String?)?.toInt() ?: 37
    // Compose BOM 2026.11 needs API 37.1 (minor SDK).
    compileSdkMinor = 1

    defaultConfig {
        applicationId = "co.deepvoiceai.example.mediapipe"
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
    implementation("co.deepvoiceai:dvai-bridge:4.3.0")
    implementation("com.squareup.okhttp3:okhttp:5.5.1")

    val composeBom = platform("androidx.compose:compose-bom:2026.11.01")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.1")

    implementation("com.aallam.openai:openai-client:4.2.0")
    implementation("io.ktor:ktor-client-okhttp:3.6.1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("com.squareup.okhttp3:okhttp:5.5.1")
}

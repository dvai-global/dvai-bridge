// Phase 2 Task 3 — `android-mediapipe` example app.
// Minimal Compose UI driving DVAIBridge.start() with BackendKind.MediaPipe.

import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "co.deepvoiceai.example.mediapipe"
    compileSdk = (project.findProperty("compileSdkOverride") as String?)?.toInt() ?: 35

    defaultConfig {
        applicationId = "co.deepvoiceai.example.mediapipe"
        minSdk = 24
        targetSdk = (project.findProperty("compileSdkOverride") as String?)?.toInt() ?: 35
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
    implementation("co.deepvoiceai:dvai-bridge:2.4.1")
    implementation("com.squareup.okhttp3:okhttp:5.3.2")

    val composeBom = platform("androidx.compose:compose-bom:2025.02.00")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.10.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")

    implementation("com.aallam.openai:openai-client:4.0.1")
    implementation("io.ktor:ktor-client-okhttp:2.3.13")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    testImplementation("com.squareup.okhttp3:okhttp:5.3.2")
}

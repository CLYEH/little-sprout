import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// scripts/ops/release-version.sh 寫入（gitignored）；缺檔 fallback 0.0.0／1，與 iOS 的 project.yml fallback 同值。
val versionProps =
    Properties().apply {
        val f = rootProject.file("version.properties")
        if (f.exists()) f.reader().use { load(it) }
    }
val appVersionName: String = versionProps.getProperty("VERSION_NAME") ?: "0.0.0"
val appVersionCode: Int = versionProps.getProperty("VERSION_CODE")?.toInt() ?: 1
val androidApi = rootProject.extra["androidApi"] as Int

android {
    namespace = "com.clyeh.sproutday"
    compileSdk = androidApi

    defaultConfig {
        applicationId = "com.clyeh.sproutday"
        minSdk = 26
        targetSdk = androidApi
        versionCode = appVersionCode
        versionName = appVersionName
        // LS-478：connectedDebugAndroidTest（CI android-connected、qa-e2e-android.sh）用的 instrumentation runner。
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":core-supabase"))
    implementation(platform(libs.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)

    testImplementation(libs.junit)

    // LS-478：instrumented 測試（TapTargetGateTest、QaDriver）。ui-test-manifest 提供 createComposeRule 要啟動的 ComponentActivity。
    debugImplementation(libs.compose.ui.test.manifest)
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.uiautomator)
}

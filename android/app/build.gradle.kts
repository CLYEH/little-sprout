import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
}

// LS-497：google-services.json 是 Firebase 設定（gitignored，由 ~/.secrets 複製進來）。缺檔時不套 google-services plugin
// （plugin 缺檔會讓建置 fail）——CI 的 android-lint／android-unit／android-connected 與沒有該檔的 worktree 都因此照常建置；
// 代價是這樣的 build 沒有 Firebase 設定，取 FCM token 在執行期 fail loud（FcmTokenSource），不影響其他功能。
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services") // 版本由 libs.versions.toml 的 google-services（root 已宣告 apply false）
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

// GOOGLE_WEB_CLIENT_ID：Google Cloud 的 OAuth「Web application」client ID（Credential Manager 的 serverClientId，
// 同一個 ID 也要填進 Supabase Auth 的 Google provider）。來自 android/local.properties（gitignored）；缺值 → 空字串，
// Google 登入在執行期 fail loud（BackendError.Misconfigured），其餘登入方式不受影響。
val localProps =
    Properties().apply {
        val f = rootProject.file("local.properties")
        if (f.exists()) f.reader().use { load(it) }
    }
val googleWebClientId: String = (localProps.getProperty("GOOGLE_WEB_CLIENT_ID") ?: "").replace("\"", "")

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
        buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", "\"$googleWebClientId\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Robolectric（Worker 冪等測試需要 Application Context）要讀合併後的資源／manifest。
    testOptions {
        unitTests.isIncludeAndroidResources = true
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
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.credentials)
    implementation(libs.androidx.credentials.play.services.auth)
    implementation(libs.googleid)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.work.runtime)
    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.messaging)
    ksp(libs.androidx.room.compiler)

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.work.testing)

    // LS-478：instrumented 測試（TapTargetGateTest、QaDriver）。ui-test-manifest 提供 createComposeRule 要啟動的 ComponentActivity。
    debugImplementation(libs.compose.ui.test.manifest)
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.uiautomator)
}

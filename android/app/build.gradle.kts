import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
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
    ksp(libs.androidx.room.compiler)

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.work.testing)
}

import java.util.Properties

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.serialization)
}

// SUPABASE_URL／SUPABASE_ANON_KEY 來自 android/local.properties（gitignored，範本 local.properties.example）；
// 缺值 → 空字串進 BuildConfig，SupabaseClientFactory 在執行期 fail loud（建置與單元測試不需要真值）。
val localProps =
    Properties().apply {
        val f = rootProject.file("local.properties")
        if (f.exists()) f.reader().use { load(it) }
    }

fun quoted(key: String): String = "\"" + (localProps.getProperty(key) ?: "").replace("\"", "\\\"") + "\""

android {
    namespace = "com.clyeh.sproutday.supabase"
    compileSdk = rootProject.extra["androidApi"] as Int

    defaultConfig {
        minSdk = 26
        buildConfigField("String", "SUPABASE_URL", quoted("SUPABASE_URL"))
        buildConfigField("String", "SUPABASE_ANON_KEY", quoted("SUPABASE_ANON_KEY"))
    }

    buildFeatures {
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
    api(platform(libs.supabase.bom))
    api(libs.supabase.auth)
    api(libs.supabase.postgrest)
    implementation(libs.ktor.client.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.junit)
}

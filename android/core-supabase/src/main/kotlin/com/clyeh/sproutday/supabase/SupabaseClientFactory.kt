package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.annotations.SupabaseInternal
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.FlowType
import io.github.jan.supabase.auth.MemoryCodeVerifierCache
import io.github.jan.supabase.auth.MemorySessionManager
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.storage.Storage

/** Supabase 連線設定。值來自 android/local.properties 經 BuildConfig（見 core-supabase/build.gradle.kts）。 */
data class SupabaseConfig(
    val url: String,
    val anonKey: String,
) {
    init {
        require(url.isNotBlank()) { "SUPABASE_URL 為空：請複製 android/local.properties.example 為 local.properties 並填值" }
        require(anonKey.isNotBlank()) {
            "SUPABASE_ANON_KEY 為空：請複製 android/local.properties.example 為 local.properties 並填值"
        }
    }
}

object SupabaseClientFactory {
    /** 與 iOS 同一組 redirect URL；須與 AndroidManifest 的 intent-filter 及 Supabase Auth 的 Redirect URLs 白名單一致。 */
    const val AUTH_SCHEME = "sproutday"
    const val AUTH_HOST = "auth"
    const val AUTH_REDIRECT_URL = "sproutday://auth/callback"

    /** 用建置時注入的 BuildConfig 值建 client；缺值 fail loud（IllegalArgumentException）。 */
    fun create(): SupabaseClient = create(SupabaseConfig(BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_ANON_KEY))

    /** 正式 client：session 持久化用 supabase-kt 預設 storage（Android 上為 SharedPreferences，Context 由 androidx.startup 注入）。 */
    fun create(config: SupabaseConfig): SupabaseClient =
        createSupabaseClient(supabaseUrl = config.url, supabaseKey = config.anonKey) {
            install(Auth) {
                scheme = AUTH_SCHEME
                host = AUTH_HOST
                defaultRedirectUrl = AUTH_REDIRECT_URL
                flowType = FlowType.PKCE // supabase-kt 3.8.0 預設 IMPLICIT（token 放 fragment 交回 app）；與 iOS 一致改用 PKCE
            }
            install(Postgrest)
            install(Storage)
        }

    /**
     * JVM 單元／契約測試用：session 與 PKCE verifier 只放記憶體、不碰 Android Context、不起背景 refresh，
     * 讓同一個 JVM 內可建多個互不干擾的使用者 client。
     */
    @OptIn(SupabaseInternal::class)
    fun createInMemory(config: SupabaseConfig): SupabaseClient =
        createSupabaseClient(supabaseUrl = config.url, supabaseKey = config.anonKey) {
            install(Auth) {
                sessionManager = MemorySessionManager()
                codeVerifierCache = MemoryCodeVerifierCache()
                autoLoadFromStorage = false
                autoSaveToStorage = false
                alwaysAutoRefresh = false
                autoSetupPlatform = false
                enableLifecycleCallbacks = false
                flowType = FlowType.PKCE
            }
            install(Postgrest)
            install(Storage)
        }
}

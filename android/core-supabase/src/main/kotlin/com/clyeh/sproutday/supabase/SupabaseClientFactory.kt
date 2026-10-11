package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.postgrest.Postgrest

/** Supabase 連線設定。值來自 android/local.properties 經 BuildConfig（見 core-supabase/build.gradle.kts）。 */
data class SupabaseConfig(val url: String, val anonKey: String) {
    init {
        require(url.isNotBlank()) { "SUPABASE_URL 為空：請複製 android/local.properties.example 為 local.properties 並填值" }
        require(anonKey.isNotBlank()) {
            "SUPABASE_ANON_KEY 為空：請複製 android/local.properties.example 為 local.properties 並填值"
        }
    }
}

object SupabaseClientFactory {
    /** 用建置時注入的 BuildConfig 值建 client；缺值 fail loud（IllegalArgumentException）。 */
    fun create(): SupabaseClient = create(SupabaseConfig(BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_ANON_KEY))

    fun create(config: SupabaseConfig): SupabaseClient =
        createSupabaseClient(supabaseUrl = config.url, supabaseKey = config.anonKey) {
            install(Postgrest)
        }
}

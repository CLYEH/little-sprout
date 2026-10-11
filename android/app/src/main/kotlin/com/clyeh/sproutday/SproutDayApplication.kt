package com.clyeh.sproutday

import android.app.Application
import com.clyeh.sproutday.supabase.SupabaseClientFactory
import io.github.jan.supabase.SupabaseClient

class SproutDayApplication : Application() {
    /** 全 app 共用一個 client（session 持久化與 auto-refresh 都在它身上）；缺 SUPABASE_URL／KEY 時第一次使用就 fail loud。 */
    val supabase: SupabaseClient by lazy { SupabaseClientFactory.create() }
}

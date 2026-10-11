package com.clyeh.sproutday

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import io.github.jan.supabase.SupabaseClient

/** release 建置的根畫面：產品畫面尚未實作前只顯示名稱；除錯登入面板只存在於 src/debug。 */
@Composable
@Suppress("UNUSED_PARAMETER")
fun RootContent(supabase: SupabaseClient) {
    Text(text = "Sprout Day")
}

package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * 推播裝置 token（docs/API.md §3 `device_tokens`、§4 `register_device_token`）。`device_tokens` 不可直接 INSERT／UPSERT／DELETE
 * （換帳號登入會被 RLS 擋、留下跨帳號推播外洩），所以只走 RPC；API.md 沒有 unregister RPC，因此這裡也不提供登出時的反註冊
 * ——換帳號時由下一個帳號呼叫 [registerDeviceToken] 接手同一個 token（RPC 先刪別人的列再插自己的）。
 */
class PushRepository(
    private val client: SupabaseClient,
) {
    /**
     * `register_device_token(p_token, p_platform := 'android')`：任何已登入使用者可呼叫；`token` 是 PK，
     * 同一個 token 重註冊只是「刪舊列再插新列」，列數不變，所以重送安全（冪等）。換 token 則新增一列、舊列不會被清掉
     * （沒有反註冊路徑；FCM 回報失效 token 時由 push-dispatch 刪列）。未登入 → [BackendError.PermissionDenied]（`42501`）。
     */
    suspend fun registerDeviceToken(token: String) {
        backend {
            client.postgrest.rpc(
                "register_device_token",
                buildJsonObject {
                    put("p_token", token)
                    put("p_platform", PLATFORM_ANDROID)
                },
            )
        }
    }

    private companion object {
        const val PLATFORM_ANDROID = "android"
    }
}

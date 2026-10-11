package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest

/** `profiles` 讀寫與 `delete_my_account`（docs/API.md §3、§4）。 */
class AccountRepository(
    private val client: SupabaseClient,
) {
    private val postgrest get() = client.postgrest

    /** 自己的 profile。`.single()` 語意：0 列代表資料不一致（`handle_new_auth_user` trigger 沒建列），fail loud。 */
    suspend fun fetchMyProfile(): Profile {
        val uid = client.requireUserId()
        return backend {
            client.from("profiles").select { filter { eq("id", uid) } }.decodeSingle<Profile>()
        }
    }

    suspend fun updateDisplayName(name: String): Profile {
        val uid = client.requireUserId()
        val rows =
            backend {
                client
                    .from("profiles")
                    .update({ set("display_name", name) }) {
                        select()
                        filter { eq("id", uid) }
                    }.decodeList<Profile>()
            }
        return rows.firstOrNull() ?: throw BackendError.NoRowsAffected("找不到自己的 profile，或沒有權限修改")
    }

    /**
     * `delete_my_account()`：只接線，本票的 UI 不呼叫。唯一 owner 且家庭還有其他成員 → [DeleteAccountOutcome.MustTransferOwnership]（`LS050`，
     * DETAIL 帶待轉移家庭清單）；其他錯誤原樣丟 [BackendError]。真正刪除 `auth.users` 由 Edge Function `delete-account` 完成（另票）。
     */
    suspend fun deleteMyAccount(): DeleteAccountOutcome =
        try {
            backend { postgrest.rpc("delete_my_account") }
            DeleteAccountOutcome.Requested
        } catch (e: BackendError.MustTransferOwnership) {
            if (e.code == "LS050") DeleteAccountOutcome.MustTransferOwnership(e.families) else throw e
        }
}

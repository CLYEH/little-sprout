package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * 寶貝檔案（docs/API.md §3 `children`、§4）。`children` 是 RPC-only（直接寫入一律 `42501`、沒有硬刪路徑），所以全部走 RPC；
 * 錯誤碼轉成 [BackendError]（`42501`／`LS041`～`LS044`），欄位驗證失敗（名字空或超過 50 字 `23514`、生日 null `23502`）落到 [BackendError.Server]。
 */
class ChildrenRepository(
    private val client: SupabaseClient,
) {
    /**
     * `create_child`：owner／member 可呼叫（viewer 得 `42501`）；回傳新寶貝 id。**不冪等**——每次呼叫都新增一筆，
     * 呼叫端重送前須先確認上一次沒成功。[birthday] 為 `yyyy-MM-dd`。
     */
    suspend fun createChild(
        familyId: String,
        name: String,
        birthday: String,
        avatarUrl: String? = null,
    ): String =
        backend {
            client.postgrest
                .rpc(
                    "create_child",
                    buildJsonObject {
                        put("p_family_id", familyId)
                        put("p_name", name)
                        put("p_birthday", birthday)
                        put("p_avatar_url", avatarUrl)
                    },
                ).decodeAs<String>()
        }

    /**
     * `update_child`：PUT 語意整組替換 name／birthday／avatar_url（不是逐欄 PATCH，所以不想動的欄位也要原值帶回）；重送結果相同。
     * 錯誤：寶貝不存在或已軟刪 [BackendError.ChildNotFound]；不是仍是該家庭 owner／member [BackendError.NotChildEditor]。
     */
    suspend fun updateChild(
        childId: String,
        name: String,
        birthday: String,
        avatarUrl: String? = null,
    ) {
        backend {
            client.postgrest.rpc(
                "update_child",
                buildJsonObject {
                    put("p_child_id", childId)
                    put("p_name", name)
                    put("p_birthday", birthday)
                    put("p_avatar_url", avatarUrl)
                },
            )
        }
    }

    /**
     * `list_children`：回傳全部列（含已軟刪，[Child.deletedAt] 非 null），依 birthday 排序；任何角色都讀得到。
     * 傳不屬於自己的家庭不報錯，只回 0 列。
     */
    suspend fun listChildren(familyId: String): List<Child> =
        backend {
            client.postgrest
                .rpc("list_children", buildJsonObject { put("p_family_id", familyId) })
                .decodeList<Child>()
        }

    /**
     * `set_child_deleted`：軟刪（`true`）／還原（`false`），**僅該家庭 owner**（其他人 `42501`）。重複軟刪是 no-op（不刷新 `deleted_at`）。
     * 還原超過 30 天 [BackendError.RestoreWindowExpired]；寶貝不存在 [BackendError.ChildNotFound]。
     * 軟刪不連動：既有日記／相簿的標記保留，但已軟刪的寶貝不能再被指定為新內容的標記（[BackendError.ChildDeleted]）。
     */
    suspend fun setChildDeleted(
        childId: String,
        deleted: Boolean,
    ) {
        backend {
            client.postgrest.rpc(
                "set_child_deleted",
                buildJsonObject {
                    put("p_child_id", childId)
                    put("p_deleted", deleted)
                },
            )
        }
    }
}

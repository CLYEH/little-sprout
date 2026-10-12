package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * 日記寫入（docs/API.md §3 `diaries`／`diary_media`／`diary_children`、§4）。讀取（時間軸、詳情）在 [FeedRepository]。
 * `diaries` 與 `diary_children` 是 RPC-only；`diary_media` 連結表 owner／member 可直接寫（§2），所以掛照片是 upsert 而非 RPC
 * （同 iOS `SupabaseDiaryAPIClient.attachMedia`）。錯誤碼轉成 [BackendError]（`LS020`／`LS021`／`LS027`／`LS044`／`42501`），
 * `body` 空或超過 20000 字 `23514`、`p_child_ids` 跨家庭 `23503` 落到 [BackendError.Server]。
 *
 * 照片先走 [MediaRepository]／上傳佇列建好 `media` 列，再 [attachMedia]：兩步不是同一個交易，第二步失敗時 media 只是尚未被引用，
 * 由後端每日排程（`soft_delete_unreferenced_media`，24 小時寬限，API.md §3 `media`）軟刪，client 不補償。
 */
class DiaryRepository(
    private val client: SupabaseClient,
) {
    /**
     * `create_diary_entry`：owner／member 可呼叫（viewer 得 `42501`）；回傳新日記 id。[childIds] 空＝家庭共用（不標記寶貝）。
     * **不冪等**——id 由後端產生、沒有 client 冪等鍵，每次呼叫都新增一篇，重送前須先確認上一次沒成功。[entryDate] 為 `yyyy-MM-dd`。
     */
    suspend fun createEntry(
        familyId: String,
        childIds: List<String>,
        body: String,
        entryDate: String,
    ): String =
        backend {
            client.postgrest
                .rpc(
                    "create_diary_entry",
                    buildJsonObject {
                        put("p_family_id", familyId)
                        put("p_child_ids", JsonArray(childIds.map(::JsonPrimitive)))
                        put("p_body", body)
                        put("p_entry_date", entryDate)
                    },
                ).decodeAs<String>()
        }

    /**
     * `update_diary_entry`：PUT 語意整組替換 body／entry_date／寶貝標記（不是逐欄 PATCH，不想動的也要原值帶回；[childIds] 空＝清空標記）；
     * 重送結果相同。只有作者本人且仍是該家庭 owner／member 能改。
     * 錯誤：非作者 [BackendError.NotDiaryAuthor]；日記不存在或已軟刪 [BackendError.DiaryNotFound]。
     */
    suspend fun updateEntry(
        diaryId: String,
        body: String,
        entryDate: String,
        childIds: List<String>,
    ) {
        backend {
            client.postgrest.rpc(
                "update_diary_entry",
                buildJsonObject {
                    put("p_diary_id", diaryId)
                    put("p_body", body)
                    put("p_entry_date", entryDate)
                    put("p_child_ids", JsonArray(childIds.map(::JsonPrimitive)))
                },
            )
        }
    }

    /**
     * `set_diary_deleted`：軟刪（`true`）／還原（`false`）；作者本人或該家庭 owner。重送結果相同。
     * owner 軟刪的日記作者無法還原 [BackendError.RemovedByOwner]；日記不存在 [BackendError.DiaryNotFound]。
     */
    suspend fun setDeleted(
        diaryId: String,
        deleted: Boolean,
    ) {
        backend {
            client.postgrest.rpc(
                "set_diary_deleted",
                buildJsonObject {
                    put("p_diary_id", diaryId)
                    put("p_deleted", deleted)
                },
            )
        }
    }

    /**
     * 把已建好 `media` 列的照片依 [mediaIds] 順序掛到日記（`sort_order`＝陣列 index）。upsert on `(diary_id, media_id)`，
     * 所以重送、或行程在中途被殺後重跑都收斂到同一個終態；[mediaIds] 空是 no-op。這支的 [familyId] 必須與日記、media 同家庭
     * （複合外鍵，跨家庭 `23503`）。
     */
    suspend fun attachMedia(
        diaryId: String,
        familyId: String,
        mediaIds: List<String>,
    ) {
        if (mediaIds.isEmpty()) return
        backend {
            client.from("diary_media").upsert(
                mediaIds.mapIndexed { index, mediaId -> DiaryMediaPayload(diaryId, mediaId, familyId, index) },
            ) {
                onConflict = "diary_id,media_id"
            }
        }
    }
}

@Serializable
private data class DiaryMediaPayload(
    @SerialName("diary_id") val diaryId: String,
    @SerialName("media_id") val mediaId: String,
    @SerialName("family_id") val familyId: String,
    @SerialName("sort_order") val sortOrder: Int,
)

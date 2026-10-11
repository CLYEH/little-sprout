package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * 留言、愛心、封鎖（docs/API.md §4）。`comments`／`reactions` 是 RPC-only（直接寫入一律 `42501`），所以全部走 RPC；
 * 錯誤碼轉成 [BackendError]（`42501`／`LS022`／`LS024`／`LS026`／`LS027`）。
 */
class SocialRepository(
    private val client: SupabaseClient,
) {
    /**
     * `create_comment`：任何角色（含 viewer）都能留言；回傳新留言 id。**不冪等**——每次呼叫都新增一則，
     * 所以這裡不自動重試；呼叫端要重送前須先確認上一次沒成功。
     * 錯誤：target 存在但屬於別的家庭 [BackendError.TargetFamilyMismatch]；body 空白或超過 2000 字 `23514`（[BackendError.Server]）。
     * 查不到的 target（孤兒 id）後端不驗證、照樣放行（API.md §3）。
     */
    suspend fun createComment(
        familyId: String,
        targetType: ContentTargetType,
        targetId: String,
        body: String,
    ): String =
        backend {
            client.postgrest
                .rpc(
                    "create_comment",
                    buildJsonObject {
                        put("p_family_id", familyId)
                        put("p_target_type", targetType.wire)
                        put("p_target_id", targetId)
                        put("p_body", body)
                    },
                ).decodeAs<String>()
        }

    /**
     * `list_comments`：未軟刪、排除呼叫者已封鎖作者的留言，`(created_at, id)` keyset 分頁。第一頁 [cursor] 傳 null，
     * 下一頁傳上一頁最後一列的 [CommentRow.cursor]（兩欄位成對送出）。[limit] 由後端夾在 1..100。非家庭成員得 `42501`。
     */
    suspend fun listComments(
        familyId: String,
        targetType: ContentTargetType,
        targetId: String,
        cursor: CommentCursor? = null,
        limit: Int = DEFAULT_PAGE_SIZE,
    ): CommentPage {
        val rows =
            backend {
                client.postgrest
                    .rpc(
                        "list_comments",
                        buildJsonObject {
                            put("p_family_id", familyId)
                            put("p_target_type", targetType.wire)
                            put("p_target_id", targetId)
                            if (cursor != null) {
                                put("p_cursor_created_at", cursor.createdAt)
                                put("p_cursor_id", cursor.id)
                            }
                            put("p_limit", limit)
                        },
                    ).decodeList<CommentRow>()
            }
        return CommentPage(rows, rows.firstOrNull()?.totalCount ?: 0)
    }

    /**
     * `set_comment_deleted`：軟刪（`true`）／還原（`false`）。作者本人或家庭 owner 可呼叫，重送結果相同（冪等）。
     * 錯誤：留言不存在 [BackendError.CommentNotFound]；owner 移除的留言作者想還原 [BackendError.RemovedByOwner]；
     * 既非作者也非 owner `42501`。
     */
    suspend fun setCommentDeleted(
        commentId: String,
        deleted: Boolean,
    ) {
        backend {
            client.postgrest.rpc(
                "set_comment_deleted",
                buildJsonObject {
                    put("p_comment_id", commentId)
                    put("p_deleted", deleted)
                },
            )
        }
    }

    /**
     * `toggle_reaction`：切換愛心。回傳值**就是切換後的最終狀態**（`true`＝已按、`false`＝已收回），呼叫端以它為準，
     * 不要自己先翻轉本機狀態——連點兩次時兩次呼叫由後端序列化，最後一次回傳的才是真相。
     * 錯誤：target 存在但屬於別的家庭 [BackendError.TargetFamilyMismatch]；不是家庭成員 `42501`。
     */
    suspend fun toggleReaction(
        familyId: String,
        targetType: ContentTargetType,
        targetId: String,
    ): Boolean =
        backend {
            client.postgrest
                .rpc(
                    "toggle_reaction",
                    buildJsonObject {
                        put("p_family_id", familyId)
                        put("p_target_type", targetType.wire)
                        put("p_target_id", targetId)
                    },
                ).decodeAs<Boolean>()
        }

    /**
     * `get_reaction_counts`：批次取愛心數與「我是否按過」。回傳以 target id 為鍵；**沒有任何愛心的 target 不在結果裡**，
     * 呼叫端要把缺席視為 0／未按。排除呼叫者已封鎖的人的愛心。傳不屬於自己的家庭不報錯，只回空。
     */
    suspend fun reactionCounts(
        familyId: String,
        targetType: ContentTargetType,
        targetIds: List<String>,
    ): Map<String, ReactionCount> {
        if (targetIds.isEmpty()) return emptyMap()
        return backend {
            client.postgrest
                .rpc(
                    "get_reaction_counts",
                    buildJsonObject {
                        put("p_family_id", familyId)
                        put("p_target_type", targetType.wire)
                        put("p_target_ids", JsonArray(targetIds.map(::JsonPrimitive)))
                    },
                ).decodeList<ReactionCount>()
        }.associateBy { it.targetId }
    }

    /**
     * `block_user`：在這個家庭封鎖某人（單向的視角過濾：時間軸、留言、相簿、愛心數都看不到對方的內容，對方不受影響）。
     * 冪等（重複封鎖不報錯）。自我封鎖 `23514`；呼叫者不是該家庭成員 `42501`。
     */
    suspend fun blockUser(
        familyId: String,
        blockedId: String,
    ) {
        backend {
            client.postgrest.rpc(
                "block_user",
                buildJsonObject {
                    put("p_family_id", familyId)
                    put("p_blocked_id", blockedId)
                },
            )
        }
    }

    /** `unblock_user`：解除封鎖；冪等（沒封鎖過也不報錯）。 */
    suspend fun unblockUser(
        familyId: String,
        blockedId: String,
    ) {
        backend {
            client.postgrest.rpc(
                "unblock_user",
                buildJsonObject {
                    put("p_family_id", familyId)
                    put("p_blocked_id", blockedId)
                },
            )
        }
    }

    private companion object {
        const val DEFAULT_PAGE_SIZE = 20
    }
}

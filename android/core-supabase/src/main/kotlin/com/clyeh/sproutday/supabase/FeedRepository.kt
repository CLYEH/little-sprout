package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * 時間軸與內容詳情的讀取（docs/API.md §3、§4）。純讀，沒有寫入，所以沒有冪等問題；錯誤碼轉成 [BackendError]。
 * 時間軸只回指標（[FeedPointer]），完整內容依 kind 另查——這裡提供日記與相簿的詳情。
 */
class FeedRepository(
    private val client: SupabaseClient,
) {
    /**
     * `get_family_timeline`：`ORDER BY occurred_at DESC, seq DESC`（同日依建立順序倒序，LS-415），keyset 分頁。
     * 第一頁 [cursor] 傳 null；下一頁傳上一頁最後一列的 [FeedPointer.cursor]。[limit] 由後端夾在 1..100。
     * [childId] 非 null＝只回標記含該寶貝的項目。游標兩個欄位一律成對送出（只送一個會得 `LS022`）。
     * 不是該家庭成員不會報錯，只會回 0 列（`security invoker`＋RLS）。
     */
    suspend fun timeline(
        familyId: String,
        childId: String? = null,
        cursor: FeedCursor? = null,
        limit: Int = DEFAULT_PAGE_SIZE,
    ): List<FeedPointer> =
        backend {
            client.postgrest
                .rpc(
                    "get_family_timeline",
                    buildJsonObject {
                        put("p_family_id", familyId)
                        if (childId != null) put("p_child_id", childId)
                        if (cursor != null) {
                            put("p_cursor_occurred_at", cursor.occurredAt)
                            put("p_cursor_ref_id", cursor.refId)
                        }
                        put("p_limit", limit)
                    },
                ).decodeList<FeedPointer>()
        }

    /** 日記詳情（日記＋照片＋寶貝標記）；不存在、看不到或已軟刪回 null。一次請求，內嵌 `diary_media`／`diary_children`。 */
    suspend fun diaryDetail(diaryId: String): DiaryDetail? =
        backend {
            client
                .from("diaries")
                .select(
                    Columns.raw(
                        "id,family_id,author_id,body,entry_date,created_at,deleted_at," +
                            "diary_media(sort_order,media!inner($MEDIA_COLUMNS)),diary_children(child_id)",
                    ),
                ) { filter { eq("id", diaryId) } }
                .decodeList<DiaryEmbedRow>()
        }.firstOrNull()?.takeIf { it.deletedAt == null }?.toDetail()

    /** 相簿詳情（相簿＋照片＋寶貝標記）；不存在、看不到（含被封鎖者建立的相簿）或已軟刪回 null。 */
    suspend fun albumDetail(albumId: String): AlbumDetail? =
        backend {
            client
                .from("albums")
                .select(
                    Columns.raw(
                        "id,family_id,title,created_by,created_at,deleted_at," +
                            "album_media(sort_order,media!inner($MEDIA_COLUMNS)),album_children(child_id)",
                    ),
                ) { filter { eq("id", albumId) } }
                .decodeList<AlbumEmbedRow>()
        }.firstOrNull()?.takeIf { it.deletedAt == null }?.toDetail()

    private companion object {
        const val DEFAULT_PAGE_SIZE = 20
    }
}

/**
 * 上傳者本人讀得到自己已軟刪的 media 列（`media_select` 的例外，docs/API.md §2），所以要在 client 端濾掉；
 * 依 `sort_order` 排序（內嵌資源的順序 PostgREST 不保證）。
 */
private fun List<MediaLink>.visibleMedia(): List<MediaRow> =
    sortedBy { it.sortOrder }.map { it.media }.filter { it.deletedAt == null }

@Serializable
private data class MediaLink(
    @SerialName("sort_order") val sortOrder: Int,
    val media: MediaRow,
)

@Serializable
private data class ChildLink(
    @SerialName("child_id") val childId: String,
)

@Serializable
private data class DiaryEmbedRow(
    val id: String,
    @SerialName("family_id") val familyId: String,
    @SerialName("author_id") val authorId: String? = null,
    val body: String,
    @SerialName("entry_date") val entryDate: String,
    @SerialName("created_at") val createdAt: String,
    @SerialName("deleted_at") val deletedAt: String? = null,
    @SerialName("diary_media") val diaryMedia: List<MediaLink> = emptyList(),
    @SerialName("diary_children") val diaryChildren: List<ChildLink> = emptyList(),
) {
    fun toDetail() =
        DiaryDetail(
            DiaryRow(id, familyId, authorId, body, entryDate, createdAt, deletedAt),
            diaryMedia.visibleMedia(),
            diaryChildren.map { it.childId },
        )
}

@Serializable
private data class AlbumEmbedRow(
    val id: String,
    @SerialName("family_id") val familyId: String,
    val title: String,
    @SerialName("created_by") val createdBy: String? = null,
    @SerialName("created_at") val createdAt: String,
    @SerialName("deleted_at") val deletedAt: String? = null,
    @SerialName("album_media") val albumMedia: List<MediaLink> = emptyList(),
    @SerialName("album_children") val albumChildren: List<ChildLink> = emptyList(),
) {
    fun toDetail() =
        AlbumDetail(
            Album(id, familyId, title, createdBy, createdAt, deletedAt),
            albumMedia.visibleMedia(),
            albumChildren.map { it.childId },
        )
}

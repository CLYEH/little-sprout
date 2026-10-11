package com.clyeh.sproutday.supabase

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * `get_family_timeline` 回傳的 `kind`（`public.feed_kind`，docs/API.md §4）。後端之後再加新值時，舊版 client 不能整頁解碼失敗
 * （API.md 對 `food_first` 的部署風險說明；iOS `FeedKind.unknown`），所以辨識不出的字串落到 [UNKNOWN]，由呼叫端濾掉。
 */
@Serializable(with = FeedKindSerializer::class)
enum class FeedKind(
    val wire: String,
) {
    DIARY("diary"),
    ALBUM("album"),
    MEDIA("media"),
    FOOD_FIRST("food_first"),
    UNKNOWN("unknown"),
}

internal object FeedKindSerializer : KSerializer<FeedKind> {
    override val descriptor = PrimitiveSerialDescriptor("FeedKind", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): FeedKind {
        val raw = decoder.decodeString()
        return FeedKind.entries.firstOrNull { it.wire == raw && it != FeedKind.UNKNOWN } ?: FeedKind.UNKNOWN
    }

    override fun serialize(
        encoder: Encoder,
        value: FeedKind,
    ) = encoder.encodeString(value.wire)
}

/** `comments`／`reactions` 的 `target_type`（`content_target_type`，docs/API.md §3）。`food_first` 不是成員（沒有留言／愛心）。 */
enum class ContentTargetType(
    val wire: String,
) {
    ALBUM("album"),
    MEDIA("media"),
    DIARY("diary"),
    COMMENT("comment"),
}

/** `food_first` 與 [FeedKind.UNKNOWN] 沒有對應的留言／愛心目標 → null。 */
val FeedKind.contentTarget: ContentTargetType?
    get() =
        when (this) {
            FeedKind.DIARY -> ContentTargetType.DIARY
            FeedKind.ALBUM -> ContentTargetType.ALBUM
            FeedKind.MEDIA -> ContentTargetType.MEDIA
            FeedKind.FOOD_FIRST, FeedKind.UNKNOWN -> null
        }

/**
 * `get_family_timeline` 的一列——只是指標（`kind`／`ref_id`），完整內容要依 kind 另查。時間欄位保留 PostgREST 回的原字串
 * （微秒精度）：翻頁時原樣當游標傳回去，不經 `Instant` 來回而損失精度。
 */
@Serializable
data class FeedPointer(
    val kind: FeedKind,
    @SerialName("ref_id") val refId: String,
    @SerialName("occurred_at") val occurredAt: String,
    /** 只有 `media` 有值（原始 EXIF 拍攝時間）；其餘 kind 恆為 null。 */
    @SerialName("taken_at") val takenAt: String? = null,
    @SerialName("child_ids") val childIds: List<String> = emptyList(),
    /** 未刪除、排除呼叫者已封鎖作者的留言數；沒有留言是 0。 */
    @SerialName("comment_count") val commentCount: Long = 0,
) {
    /** 以這一列當「下一頁」的游標（取一頁的最後一列）。 */
    val cursor: FeedCursor get() = FeedCursor(occurredAt, refId)
}

/** keyset 游標 `(occurred_at, ref_id)`：一對一起傳，型別層面杜絕只傳一半（`LS022`）。 */
data class FeedCursor(
    val occurredAt: String,
    val refId: String,
)

/** `list_comments` 的一列；`total_count` 每列相同＝這個 target 全部符合條件的留言數。作者可能已離開（`author_id` 為 null）。 */
@Serializable
data class CommentRow(
    val id: String,
    @SerialName("author_id") val authorId: String? = null,
    @SerialName("author_display_name") val authorDisplayName: String? = null,
    @SerialName("author_avatar_url") val authorAvatarUrl: String? = null,
    val body: String,
    @SerialName("created_at") val createdAt: String,
    @SerialName("total_count") val totalCount: Long = 0,
) {
    val cursor: CommentCursor get() = CommentCursor(createdAt, id)
}

/** `list_comments` 的 keyset 游標 `(created_at, id)`。 */
data class CommentCursor(
    val createdAt: String,
    val id: String,
)

/** 一頁留言。`totalCount` 取自任一列；0 列＝這個 target 沒有任何留言（API.md：0 列本身就是 `total_count = 0`）。 */
data class CommentPage(
    val comments: List<CommentRow>,
    val totalCount: Long,
)

/** `get_reaction_counts` 的一列；沒有任何愛心的 target 不會出現（呼叫端視為 0，見 [SocialRepository.reactionCounts]）。 */
@Serializable
data class ReactionCount(
    @SerialName("target_id") val targetId: String,
    @SerialName("reaction_count") val reactionCount: Long,
    @SerialName("reacted_by_me") val reactedByMe: Boolean,
)

/** `public.diaries` 可讀欄位子集（`entry_date` 是 Postgres `date`，保留 `yyyy-MM-dd` 字串）。 */
@Serializable
data class DiaryRow(
    val id: String,
    @SerialName("family_id") val familyId: String,
    @SerialName("author_id") val authorId: String? = null,
    val body: String,
    @SerialName("entry_date") val entryDate: String,
    @SerialName("created_at") val createdAt: String,
    @SerialName("deleted_at") val deletedAt: String? = null,
)

/** 日記詳情：日記本體＋未軟刪的照片（依 `sort_order`）＋標記的寶貝 id。 */
data class DiaryDetail(
    val diary: DiaryRow,
    val media: List<MediaRow>,
    val childIds: List<String>,
)

/** 相簿詳情：相簿本體＋未軟刪的照片（依 `sort_order`）＋標記的寶貝 id。 */
data class AlbumDetail(
    val album: Album,
    val media: List<MediaRow>,
    val childIds: List<String>,
)

package com.clyeh.sproutday.supabase

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.ZoneOffset
import java.util.Locale

/** `public.albums` 可讀欄位子集（docs/API.md §2、§3）。 */
@Serializable
data class Album(
    val id: String,
    @SerialName("family_id") val familyId: String,
    val title: String,
    @SerialName("created_by") val createdBy: String? = null,
    @SerialName("created_at") val createdAt: String,
    @SerialName("deleted_at") val deletedAt: String? = null,
)

/** `public.media` 可讀欄位子集；`deleted_at` 非 null＝已軟刪（上傳者本人仍讀得到自己的已軟刪列，docs/API.md §2）。 */
@Serializable
data class MediaRow(
    val id: String,
    @SerialName("family_id") val familyId: String,
    @SerialName("storage_path") val storagePath: String,
    val type: String,
    @SerialName("byte_size") val byteSize: Long,
    val width: Int,
    val height: Int,
    @SerialName("thumb_path") val thumbPath: String? = null,
    @SerialName("thumb_width") val thumbWidth: Int? = null,
    @SerialName("thumb_height") val thumbHeight: Int? = null,
    @SerialName("created_at") val createdAt: String,
    @SerialName("deleted_at") val deletedAt: String? = null,
)

/** 縮圖實際輸出的檔案路徑與像素尺寸；`media` 的三個 `thumb_*` 欄同為 NULL 或同為非 NULL（CHECK），所以包成一個值。 */
data class ThumbnailInfo(
    val path: String,
    val width: Int,
    val height: Int,
)

/** `media` 的一筆 INSERT（`uploaded_by` 由 [MediaRepository] 取自目前 session，不由呼叫端傳入）。 */
data class NewMedia(
    val id: String,
    val familyId: String,
    val storagePath: String,
    val byteSize: Long,
    val width: Int,
    val height: Int,
    val thumbnail: ThumbnailInfo?,
)

/** Storage 與 `media` 表的客戶端契約常數（docs/API.md §6；iOS `MediaUploadLimits`／`SupabaseMediaUploadService`）。 */
object MediaLimits {
    const val BUCKET = "media"

    /** 單檔 50 MiB，Storage bucket 的 `file_size_limit`；超過會被 Storage 以 413 擋下。 */
    const val MAX_OBJECT_BYTES = 50L * 1024 * 1024

    /** 縮圖規格：長邊 ≤ 512px、JPEG 品質 0.8（iOS `thumbnailMaxPixelSize`／`thumbnailJPEGQuality`）。 */
    const val THUMBNAIL_MAX_EDGE_PX = 512
    const val THUMBNAIL_JPEG_QUALITY_PERCENT = 80
    const val THUMBNAIL_CONTENT_TYPE = "image/jpeg"

    /** Bucket 的 `allowed_mime_types` 中本票支援的照片副檔名（影片不在本票範圍）。 */
    private val photoContentTypes =
        mapOf(
            "jpg" to "image/jpeg",
            "jpeg" to "image/jpeg",
            "png" to "image/png",
            "heic" to "image/heic",
            "heif" to "image/heif",
        )

    fun photoContentType(extension: String): String? = photoContentTypes[extension.lowercase(Locale.ROOT)]
}

/** Storage 路徑規約（docs/API.md §6）：`{family_id}/{yyyy}/{mm}/{media_id}.{ext}` 與 `..._thumb.jpg`。 */
object MediaPaths {
    /**
     * `yyyy/mm` 取**上傳時間**（UTC，避免裝置時區造成月界不一致）；`family_id`／`media_id` 必須是小寫正規形 UUID
     * （`media.storage_path` 的 CHECK 比對 Postgres 的小寫 `uuid::text`），所以這裡一律 lowercase。
     */
    fun original(
        familyId: String,
        mediaId: String,
        extension: String,
        at: Instant,
    ): String = "${prefix(familyId, mediaId, at)}.${extension.lowercase(Locale.ROOT)}"

    fun thumbnail(
        familyId: String,
        mediaId: String,
        at: Instant,
    ): String = "${prefix(familyId, mediaId, at)}_thumb.jpg"

    private fun prefix(
        familyId: String,
        mediaId: String,
        at: Instant,
    ): String {
        val utc = at.atZone(ZoneOffset.UTC)
        return "${familyId.lowercase(Locale.ROOT)}/%04d/%02d/${mediaId.lowercase(Locale.ROOT)}".format(
            Locale.ROOT,
            utc.year,
            utc.monthValue,
        )
    }
}

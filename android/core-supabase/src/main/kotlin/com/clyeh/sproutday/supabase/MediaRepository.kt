package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.storage.UploadData
import io.github.jan.supabase.storage.storage
import io.ktor.http.ContentType
import io.ktor.util.cio.readChannel
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.io.IOException
import java.time.Instant

/**
 * 上傳佇列需要的後端動作（docs/API.md §3「上傳流程順序」）。抽成介面是為了讓 Worker 的單元測試不必起後端；
 * 所有方法都必須**可重送**：系統會重跑同一筆 work，行程可能在任何兩步之間被殺。
 */
interface MediaUploadBackend {
    /**
     * 確認已有可用的登入 session 才打網路：先等 auth 初始化完成（冷啟動時 session 由背景協程從 storage 載入，沒等就送請求會帶
     * anon key 被 RLS 擋下，被誤判成終局失敗）。沒有 session → [BackendError.NotSignedIn]；session 載入後 refresh 失敗 →
     * [BackendError.Network]。兩者都是暫時性錯誤（見 [isTransient]）。
     */
    suspend fun ensureSession()

    /** PUT 一個本機檔到 `media` bucket（`upsert`：同路徑覆寫，重送不會因「已存在」失敗）。串流上傳，不整檔讀進記憶體。 */
    suspend fun uploadFile(
        path: String,
        file: File,
        contentType: String,
    )

    suspend fun uploadBytes(
        path: String,
        bytes: ByteArray,
        contentType: String,
    )

    /** INSERT `media` 列；主鍵已存在（`23505`）＝上一次嘗試已寫入、回應遺失，視為成功。額度爆了 → [BackendError.StorageQuotaExceeded]。 */
    suspend fun insertMedia(media: NewMedia)

    /** 把 media 掛進相簿（`album_media`）；已掛過則保持原排序、不重複建列。 */
    suspend fun attachToAlbum(
        albumId: String,
        familyId: String,
        mediaId: String,
    )

    /** 刪 Storage 物件（上傳者對自己上傳的物件有 DELETE 權限，docs/API.md §6）；呼叫端 best-effort。 */
    suspend fun deleteObjects(paths: List<String>)
}

/**
 * `albums`／`album_media`／`media` 與 Storage `media` bucket 的讀寫（docs/API.md §2–§4、§6）。錯誤碼轉成 [BackendError]。
 * 沒有 `create_album` RPC：建相簿是直接 INSERT `albums`（同 [FamilyRepository.createFamily] 的作法）；
 * 軟刪相簿的唯一路徑是 `set_album_deleted` RPC，軟刪照片是 UPDATE `media.deleted_at`（欄位級 grant）。
 */
@Suppress("TooManyFunctions") // 一支 repository 對應 albums／media／Storage 的一組動作（含 [MediaUploadBackend] 五個）
class MediaRepository(
    private val client: SupabaseClient,
) : MediaUploadBackend {
    private val bucket get() = client.storage.from(MediaLimits.BUCKET)

    /** 建相簿：`created_by` 必須是自己。可能的錯誤：`LS051`／`LS052`／`LS053`、viewer 為 `42501`。 */
    suspend fun createAlbum(
        familyId: String,
        title: String,
    ): Album {
        val uid = client.requireUserId()
        return backend {
            client
                .from("albums")
                .insert(CreateAlbumPayload(familyId = familyId, title = title, createdBy = uid)) { select() }
                .decodeSingle<Album>()
        }
    }

    /** 家庭未軟刪的相簿，最新的在前。 */
    suspend fun listAlbums(familyId: String): List<Album> =
        backend {
            client
                .from("albums")
                .select {
                    filter {
                        eq("family_id", familyId)
                        exact("deleted_at", null)
                    }
                    order("created_at", Order.DESCENDING)
                }.decodeList<Album>()
        }

    /** `set_album_deleted(p_album_id, p_deleted)`：建立者或家庭 owner 軟刪（`true`）／還原（`false`）相簿。 */
    suspend fun setAlbumDeleted(
        albumId: String,
        deleted: Boolean,
    ) {
        backend {
            client.postgrest.rpc(
                "set_album_deleted",
                buildJsonObject {
                    put("p_album_id", albumId)
                    put("p_deleted", deleted)
                },
            )
        }
    }

    /**
     * 相簿裡**未軟刪**的照片，依 `sort_order` 排序。上傳者本人讀得到自己已軟刪的列（`media_select` 的例外），
     * 所以這裡明確濾掉 `deleted_at`，不能靠 RLS。
     */
    suspend fun listAlbumMedia(albumId: String): List<MediaRow> =
        backend {
            client
                .from("album_media")
                .select(Columns.raw("sort_order, media!inner($MEDIA_COLUMNS)")) {
                    filter { eq("album_id", albumId) }
                    order("sort_order", Order.ASCENDING)
                }.decodeList<AlbumMediaRow>()
        }.map { it.media }.filter { it.deletedAt == null }

    /** 軟刪照片：UPDATE `media.deleted_at`（上傳者本人，或家庭 owner）。匹配 0 列（RLS USING 過濾）→ [BackendError.NoRowsAffected]。 */
    suspend fun softDeleteMedia(mediaIds: List<String>) {
        if (mediaIds.isEmpty()) return
        val rows =
            backend {
                client
                    .from("media")
                    .update({ set("deleted_at", Instant.now().toString()) }) {
                        select(Columns.raw("id"))
                        filter { isIn("id", mediaIds) }
                    }.decodeList<MediaIdRow>()
            }
        if (rows.isEmpty()) throw BackendError.NoRowsAffected("沒有權限刪除這些照片，或照片不存在")
    }

    override suspend fun ensureSession() {
        client.auth.awaitInitialization()
        if (client.auth.sessionStatus.value is SessionStatus.RefreshFailure) {
            throw BackendError.Network(IOException("session 重新整理失敗（離線？）"))
        }
        client.requireUserId()
    }

    override suspend fun uploadFile(
        path: String,
        file: File,
        contentType: String,
    ) {
        backend {
            bucket.upload(path, UploadData(file.readChannel(), file.length())) {
                upsert = true
                this.contentType = ContentType.parse(contentType)
            }
        }
    }

    override suspend fun uploadBytes(
        path: String,
        bytes: ByteArray,
        contentType: String,
    ) {
        backend {
            bucket.upload(path, bytes) {
                upsert = true
                this.contentType = ContentType.parse(contentType)
            }
        }
    }

    override suspend fun insertMedia(media: NewMedia) {
        val uid = client.requireUserId()
        try {
            backend {
                client.from("media").insert(
                    MediaInsertPayload(
                        id = media.id,
                        familyId = media.familyId,
                        storagePath = media.storagePath,
                        type = "photo",
                        byteSize = media.byteSize,
                        width = media.width,
                        height = media.height,
                        uploadedBy = uid,
                        thumbPath = media.thumbnail?.path,
                        thumbWidth = media.thumbnail?.width,
                        thumbHeight = media.thumbnail?.height,
                    ),
                )
            }
        } catch (e: BackendError.Server) {
            // 主鍵衝突：同一個 media id 的 INSERT 先前已 commit（回應遺失才會重送），不是失敗。
            if (e.code != UNIQUE_VIOLATION) throw e
        }
    }

    override suspend fun attachToAlbum(
        albumId: String,
        familyId: String,
        mediaId: String,
    ) {
        backend {
            val maxSort =
                client
                    .from("album_media")
                    .select(Columns.raw("sort_order")) {
                        filter { eq("album_id", albumId) }
                        order("sort_order", Order.DESCENDING)
                        limit(1)
                    }.decodeList<SortOrderRow>()
                    .firstOrNull()
                    ?.sortOrder
            client.from("album_media").upsert(
                AlbumMediaPayload(albumId, mediaId, familyId, (maxSort ?: -1) + 1),
            ) {
                onConflict = "album_id,media_id"
                ignoreDuplicates = true // 已掛過就保持原排序（重跑不重排）
            }
        }
    }

    override suspend fun deleteObjects(paths: List<String>) {
        if (paths.isEmpty()) return
        backend { bucket.delete(paths) }
    }

    private companion object {
        const val UNIQUE_VIOLATION = "23505"
        const val MEDIA_COLUMNS =
            "id,family_id,storage_path,type,byte_size,width,height," +
                "thumb_path,thumb_width,thumb_height,created_at,deleted_at"
    }
}

@Serializable
private data class CreateAlbumPayload(
    @SerialName("family_id") val familyId: String,
    val title: String,
    @SerialName("created_by") val createdBy: String,
)

@Serializable
private data class AlbumMediaRow(
    @SerialName("sort_order") val sortOrder: Int,
    val media: MediaRow,
)

@Serializable
private data class MediaIdRow(
    val id: String,
)

@Serializable
private data class SortOrderRow(
    @SerialName("sort_order") val sortOrder: Int,
)

@Serializable
private data class AlbumMediaPayload(
    @SerialName("album_id") val albumId: String,
    @SerialName("media_id") val mediaId: String,
    @SerialName("family_id") val familyId: String,
    @SerialName("sort_order") val sortOrder: Int,
)

@Serializable
private data class MediaInsertPayload(
    val id: String,
    @SerialName("family_id") val familyId: String,
    @SerialName("storage_path") val storagePath: String,
    val type: String,
    @SerialName("byte_size") val byteSize: Long,
    val width: Int,
    val height: Int,
    @SerialName("uploaded_by") val uploadedBy: String,
    @SerialName("thumb_path") val thumbPath: String?,
    @SerialName("thumb_width") val thumbWidth: Int?,
    @SerialName("thumb_height") val thumbHeight: Int?,
)

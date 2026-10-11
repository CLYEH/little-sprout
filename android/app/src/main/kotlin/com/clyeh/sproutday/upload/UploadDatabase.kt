package com.clyeh.sproutday.upload

import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.RoomDatabase
import kotlinx.coroutines.flow.Flow

/** 佇列一筆的狀態。`UPLOADING` 也可能是行程被殺後遺留的——worker 重跑時 [PENDING]／[UPLOADING] 一律可認領。 */
enum class UploadState {
    PENDING,
    UPLOADING,
    DONE,

    /** 終局失敗（額度、權限、檔案壞掉、重試次數用盡）；不會再被 worker 認領。 */
    FAILED,
}

/**
 * 上傳佇列一筆。[id] 同時是 `media.id` 與 WorkManager unique work 名稱的一部分——整條重送鏈（物件路徑、media 主鍵、相簿連結）
 * 都由它推導，所以重送是冪等的。路徑在入列時就定下（取入列當下的 UTC 年月），跨月重試也不會換路徑。
 */
@Entity(tableName = "upload_items")
data class UploadItem(
    @PrimaryKey val id: String,
    val familyId: String,
    val albumId: String?,
    /** App 私有目錄裡的副本（選圖 URI 的存取權可能隨行程結束而消失，所以入列時就複製）。 */
    val localPath: String,
    val extension: String,
    val storagePath: String,
    val thumbPath: String,
    val state: UploadState,
    val attempt: Int,
    val lastError: String?,
    val createdAt: Long,
)

@Dao
interface UploadDao {
    /** 回傳 -1＝同 id 已存在（被 IGNORE）。 */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(item: UploadItem): Long

    @Query("SELECT * FROM upload_items WHERE id = :id")
    suspend fun get(id: String): UploadItem?

    @Query("SELECT * FROM upload_items ORDER BY createdAt DESC")
    fun observeAll(): Flow<List<UploadItem>>

    @Query("SELECT * FROM upload_items WHERE state IN ('PENDING', 'UPLOADING')")
    suspend fun unfinished(): List<UploadItem>

    /** 認領：只有未終局的列會被改成 UPLOADING 並累計次數；回傳 0＝已終局（DONE／FAILED）或已被清掉。 */
    @Query(
        "UPDATE upload_items SET state = 'UPLOADING', attempt = attempt + 1 " +
            "WHERE id = :id AND state IN ('PENDING', 'UPLOADING')",
    )
    suspend fun claim(id: String): Int

    /** 終局寫入（DONE／FAILED）；同樣只動未終局的列，已被登出清掉的不會復活。 */
    @Query(
        "UPDATE upload_items SET state = :state, lastError = :error " +
            "WHERE id = :id AND state IN ('PENDING', 'UPLOADING')",
    )
    suspend fun finish(
        id: String,
        state: UploadState,
        error: String?,
    ): Int

    /** 暫時性失敗：放回 PENDING 等 WorkManager 退避後重跑。 */
    @Query("UPDATE upload_items SET state = 'PENDING', lastError = :error WHERE id = :id AND state = 'UPLOADING'")
    suspend fun release(
        id: String,
        error: String?,
    ): Int

    /** 登出：清掉所有未完成的列（DONE 保留當歷史）。 */
    @Query("DELETE FROM upload_items WHERE state != 'DONE'")
    suspend fun deleteUnfinished(): Int
}

@Database(entities = [UploadItem::class], version = 1, exportSchema = false)
abstract class UploadDatabase : RoomDatabase() {
    abstract fun dao(): UploadDao
}

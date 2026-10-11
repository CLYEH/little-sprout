package com.clyeh.sproutday.upload

import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.await
import androidx.work.workDataOf
import com.clyeh.sproutday.supabase.MediaLimits
import com.clyeh.sproutday.supabase.MediaPaths
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.time.Instant
import java.util.Locale
import java.util.concurrent.TimeUnit

/** 選到的一張圖：開串流的方法與 MIME（呼叫端用 ContentResolver 提供；佇列不認識 Uri，測試也不必造 Uri）。 */
class UploadSource(
    val mimeType: String?,
    val open: () -> InputStream,
)

/** 入列前就能判定不可能上傳成功的來源（不支援的格式、超過 50 MiB）。 */
class UploadRejectedException(
    message: String,
) : Exception(message)

/**
 * 照片上傳佇列：Room 狀態列（真相）＋ WorkManager unique work（執行）。入列時把來源複製進 App 私有目錄，之後行程被殺、
 * 選圖 URI 失效都不影響續傳；[resumeAll] 在 App 啟動時把未完成項目重新排進 WorkManager（`KEEP`，已在排的不受影響）。
 */
class UploadQueue(
    private val directory: File,
    private val dao: UploadDao,
    private val workManager: WorkManager,
    private val clock: () -> Instant = Instant::now,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val enqueueLock = Mutex()

    val items: Flow<List<UploadItem>> = dao.observeAll()

    /**
     * 入列一張照片。[id] 是呼叫端給的**冪等鍵**（同時會成為 `media.id`）：同一個 id 再呼叫（連點、旋轉重送）回傳既有那一列、
     * 不複製、不重排。每次選圖應產生一個新 id；沒有跨次去重的語意。
     * @throws UploadRejectedException 格式不支援或超過 50 MiB
     */
    suspend fun enqueue(
        id: String,
        familyId: String,
        albumId: String?,
        source: UploadSource,
    ): UploadItem {
        val itemId = id.lowercase(Locale.ROOT)
        // 入列串行化：同 id 並發入列時，後到者等鎖、進鎖後看到既有列直接回傳，不會兩邊同時寫同一個副本檔。
        return enqueueLock.withLock {
            dao.get(itemId) ?: createItem(itemId, familyId, albumId, source).also {
                dao.insert(it)
                schedule(itemId)
            }
        }
    }

    /** App 啟動時呼叫：入列到排程之間被殺的項目（有列、沒 work）在這裡補排。`KEEP`：已在排／執行中的不動。 */
    suspend fun resumeAll() {
        dao.unfinished().forEach { schedule(it.id) }
    }

    /** 登出：取消所有排程中的 work、刪掉未完成（含 FAILED）的列與其本機副本。正在跑的 worker 會收到取消（協程取消，不吞）。 */
    suspend fun clear() {
        workManager.cancelAllWorkByTag(TAG).await()
        val doomed = dao.notDone()
        dao.deleteNotDone()
        withContext(io) { doomed.forEach { File(it.localPath).delete() } }
    }

    internal fun schedule(id: String) {
        val request =
            OneTimeWorkRequestBuilder<UploadWorker>()
                .setInputData(workDataOf(UploadWorker.KEY_ITEM_ID to id))
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, BACKOFF_SECONDS, TimeUnit.SECONDS)
                .addTag(TAG)
                .build()
        workManager.enqueueUniqueWork(workName(id), ExistingWorkPolicy.KEEP, request)
    }

    private suspend fun createItem(
        id: String,
        familyId: String,
        albumId: String?,
        source: UploadSource,
    ): UploadItem {
        val extension = extensionOf(source.mimeType)
        val target = File(directory, "$id.$extension")
        withContext(io) { copyWithLimit(source, target) }
        val now = clock()
        return UploadItem(
            id = id,
            familyId = familyId,
            albumId = albumId,
            localPath = target.path,
            extension = extension,
            storagePath = MediaPaths.original(familyId, id, extension, now),
            thumbPath = MediaPaths.thumbnail(familyId, id, now),
            state = UploadState.PENDING,
            attempt = 0,
            lastError = null,
            createdAt = now.toEpochMilli(),
        )
    }

    private fun extensionOf(mimeType: String?): String =
        when (mimeType?.lowercase(Locale.ROOT)) {
            "image/jpeg", "image/jpg" -> "jpg"
            "image/png" -> "png"
            "image/heic" -> "heic"
            "image/heif" -> "heif"
            else -> throw UploadRejectedException("不支援的格式：$mimeType（支援 jpg／png／heic／heif）")
        }.also { check(MediaLimits.photoContentType(it) != null) }

    /** 邊複製邊計數，超過上限就中止並刪掉半成品，不先把超大檔整份寫進磁碟。 */
    private fun copyWithLimit(
        source: UploadSource,
        target: File,
    ) {
        target.parentFile?.mkdirs()
        var copied = false
        try {
            source.open().use { input -> target.outputStream().use { output -> copyCounting(input, output) } }
            copied = true
        } finally {
            if (!copied) target.delete()
        }
    }

    private fun copyCounting(
        input: InputStream,
        output: OutputStream,
    ) {
        val buffer = ByteArray(COPY_BUFFER_BYTES)
        var total = 0L
        var read = input.read(buffer)
        while (read >= 0) {
            total += read
            if (total > MediaLimits.MAX_OBJECT_BYTES) throw UploadRejectedException("檔案超過 50 MiB 上限")
            output.write(buffer, 0, read)
            read = input.read(buffer)
        }
    }

    companion object {
        const val TAG = "upload-queue"
        private const val BACKOFF_SECONDS = 30L
        private const val COPY_BUFFER_BYTES = 64 * 1024

        fun workName(id: String): String = "upload-$id"
    }
}

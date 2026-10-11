package com.clyeh.sproutday.upload

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ListenableWorker
import androidx.work.WorkerFactory
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.clyeh.sproutday.supabase.BackendError
import com.clyeh.sproutday.supabase.MediaLimits
import com.clyeh.sproutday.supabase.MediaUploadBackend
import com.clyeh.sproutday.supabase.NewMedia
import com.clyeh.sproutday.supabase.ThumbnailInfo
import com.clyeh.sproutday.supabase.isTransient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

/** Worker 的依賴（Worker 由系統反射建立，所以經 [UploadWorkerFactory] 注入；測試換成假的後端）。 */
class UploadDependencies(
    val dao: UploadDao,
    val backend: Lazy<MediaUploadBackend>,
    val preparer: MediaPreparer,
)

class UploadWorkerFactory(
    private val deps: UploadDependencies,
) : WorkerFactory() {
    override fun createWorker(
        appContext: Context,
        workerClassName: String,
        workerParameters: WorkerParameters,
    ): ListenableWorker? =
        if (workerClassName == UploadWorker::class.java.name) UploadWorker(appContext, workerParameters, deps) else null
}

/**
 * 上傳一筆佇列項（docs/API.md §3「上傳流程順序」：① 原檔 PUT ② 縮圖 PUT（①② 並行）③ INSERT `media` ④ 掛進相簿）。
 *
 * **冪等**（系統會重跑、重試，行程可能在任兩步之間被殺）：
 * - 項目 id 就是 `media.id` 與物件路徑的來源，路徑在入列時定下；重跑時物件 `upsert` 覆寫、`media` 主鍵衝突當成功、
 *   相簿連結 `ignoreDuplicates`，所以「物件已上傳、media 列未寫」「media 已寫、回應遺失」「已掛進相簿」三種中斷點重跑都收斂到同一個結果。
 * - 已終局（DONE／FAILED）或已被登出清掉的項目，重跑直接成功返回、不碰網路。
 * - 取消（登出、系統停掉 worker）時 [CancellationException] 原樣往上傳；狀態留在 UPLOADING，下次重跑可再認領。
 */
class UploadWorker(
    appContext: Context,
    params: WorkerParameters,
    private val deps: UploadDependencies,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val id = inputData.getString(KEY_ITEM_ID)
        val item = id?.let { deps.dao.get(it) }
        return when {
            id == null -> Result.failure()
            // 沒有列（已清）或已終局：什麼都不做。claim 的條件式 UPDATE 再擋一次「讀到之後才被終局」的窗口。
            item == null || item.state.isTerminal || deps.dao.claim(id) == 0 -> Result.success()
            else -> attempt(item)
        }
    }

    private suspend fun attempt(item: UploadItem): Result {
        val attemptNumber = item.attempt + 1
        return try {
            process(item)
            deps.dao.finish(item.id, UploadState.DONE, null)
            File(item.localPath).delete()
            Result.success()
        } catch (e: CancellationException) {
            throw e
        } catch (e: BackendError) {
            if (e.isTransient && attemptNumber < MAX_ATTEMPTS) {
                deps.dao.release(item.id, e.code ?: e.message)
                Result.retry()
            } else {
                failTerminal(item, e.code ?: e.message)
            }
        } catch (e: UnreadableMediaException) {
            failTerminal(item, e.message)
        } catch (e: IOException) {
            failTerminal(item, "本機檔案讀取失敗：${e.message}") // 副本不見／讀不到，重試不會變好
        }
    }

    private suspend fun failTerminal(
        item: UploadItem,
        error: String?,
    ): Result {
        deps.dao.finish(item.id, UploadState.FAILED, error)
        File(item.localPath).delete()
        return Result.failure(workDataOf(KEY_ERROR to error))
    }

    private suspend fun process(item: UploadItem) {
        val file = File(item.localPath)
        if (!file.exists()) throw IOException("入列時的本機副本不存在：${file.name}")
        val prepared = withContext(Dispatchers.IO) { deps.preparer.prepare(file) }
        val backend = deps.backend.value
        val contentType = checkNotNull(MediaLimits.photoContentType(item.extension)) { "不支援的副檔名 ${item.extension}" }
        coroutineScope {
            launch { backend.uploadFile(item.storagePath, file, contentType) }
            prepared.thumbnail?.let {
                launch {
                    backend.uploadBytes(
                        item.thumbPath,
                        it.bytes,
                        MediaLimits.THUMBNAIL_CONTENT_TYPE,
                    )
                }
            }
        }
        val media =
            NewMedia(
                id = item.id,
                familyId = item.familyId,
                storagePath = item.storagePath,
                byteSize = file.length(),
                width = prepared.width,
                height = prepared.height,
                thumbnail = prepared.thumbnail?.let { ThumbnailInfo(item.thumbPath, it.width, it.height) },
            )
        try {
            backend.insertMedia(media)
        } catch (e: BackendError.StorageQuotaExceeded) {
            // LS002：這次 INSERT 一定沒 commit（主鍵衝突會先於額度 trigger 以 23505 出現），已上傳的物件確定是孤兒，client 自己清（docs/API.md §3）。
            // 其他失敗（逾時、權限）無法確定先前的嘗試有沒有 commit 過，不清——清了可能留下一列指向不存在檔案的 media；交給伺服器的孤兒掃描。
            cleanupOrphans(
                backend,
                listOfNotNull(item.storagePath, item.thumbPath.takeIf { prepared.thumbnail != null }),
            )
            throw e
        }
        item.albumId?.let { backend.attachToAlbum(it, item.familyId, item.id) }
    }

    @Suppress("SwallowedException") // best-effort：清不掉不蓋過原始錯誤，伺服器的孤兒掃描（LS-213）會回收
    private suspend fun cleanupOrphans(
        backend: MediaUploadBackend,
        paths: List<String>,
    ) {
        try {
            backend.deleteObjects(paths)
        } catch (e: BackendError) {
            // 見註解
        }
    }

    companion object {
        const val KEY_ITEM_ID = "item_id"
        const val KEY_ERROR = "error"

        /** 暫時性失敗最多嘗試次數（含第一次），用盡轉 FAILED；WorkManager 以指數退避排程每次重試。 */
        const val MAX_ATTEMPTS = 5
    }
}

private val UploadState.isTerminal: Boolean get() = this == UploadState.DONE || this == UploadState.FAILED

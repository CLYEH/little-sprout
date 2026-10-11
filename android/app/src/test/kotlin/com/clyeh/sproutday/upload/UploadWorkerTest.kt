package com.clyeh.sproutday.upload

import android.app.Application
import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.TestListenableWorkerBuilder
import androidx.work.testing.WorkManagerTestInitHelper
import androidx.work.workDataOf
import com.clyeh.sproutday.supabase.BackendError
import com.clyeh.sproutday.supabase.MediaUploadBackend
import com.clyeh.sproutday.supabase.NewMedia
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * 上傳佇列的冪等與恢復（LS-490）：WorkManager 會重跑同一筆、行程可能在任兩步之間被殺，所以
 * 「同一筆重跑 N 次」必須收斂到同一個伺服器端結果（一列 media、一組物件路徑、一條相簿連結）。
 */
@RunWith(RobolectricTestRunner::class)
// Robolectric 4.17 的 SDK 清單到 35（compileSdk 36 的 android-all 尚未提供），測試固定跑 35。
@Config(sdk = [35], application = Application::class)
class UploadWorkerTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val backend = FakeBackend()
    private lateinit var db: UploadDatabase
    private lateinit var factory: UploadWorkerFactory
    private lateinit var workManager: WorkManager
    private lateinit var queue: UploadQueue

    private val familyId = UUID.randomUUID().toString()
    private val albumId = UUID.randomUUID().toString()

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(context, UploadDatabase::class.java).allowMainThreadQueries().build()
        val preparer = MediaPreparer { PreparedMedia(640, 480, PreparedThumbnail(byteArrayOf(1, 2, 3), 512, 384)) }
        factory = UploadWorkerFactory(UploadDependencies(db.dao(), lazy { backend }, preparer))
        WorkManagerTestInitHelper.initializeTestWorkManager(
            context,
            Configuration
                .Builder()
                .setWorkerFactory(factory)
                .setExecutor(SynchronousExecutor())
                .build(),
        )
        workManager = WorkManager.getInstance(context)
        queue = UploadQueue(tmp.newFolder(), db.dao(), workManager, clock = { Instant.parse("2026-10-12T03:00:00Z") })
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun rerunningAFinishedItemDoesNotUploadAgain() =
        runBlocking<Unit> {
            val item = queue.enqueue(newId(), familyId, albumId, jpegSource())
            runScheduledWork(item.id)

            assertEquals(UploadState.DONE, db.dao().get(item.id)?.state)
            assertEquals("原檔＋縮圖各上傳一次", 2, backend.uploadCalls.get())
            assertEquals(1, backend.mediaRows.size)
            assertFalse("DONE 後本機副本要清掉", File(item.localPath).exists())

            // 系統重跑同一筆（例如行程重啟後 resumeAll、或 work 被重送）：上一個 work 已 SUCCEEDED，KEEP 會排入新的一個。
            queue.schedule(item.id)
            val rerun = runScheduledWork(item.id)

            assertEquals("重跑必須是成功的 no-op，不是失敗", WorkInfo.State.SUCCEEDED, rerun.state)
            assertEquals("重跑不得再上傳任何物件", 2, backend.uploadCalls.get())
            assertEquals("重跑不得再寫 media", 1, backend.insertCalls.get())
            assertEquals("重跑不得再掛相簿", 1, backend.attachCalls.get())
        }

    @Test
    fun retryAfterTransientFailureConvergesOnSameMediaIdAndPaths() =
        runBlocking<Unit> {
            val item = queue.enqueue(newId(), familyId, albumId, jpegSource())
            backend.failAttachOnce = BackendError.Network(IOException("斷線"))

            // 第一次：物件已上傳、media 列已寫、掛相簿時斷線 → 退避重試，狀態放回 PENDING。
            val first = buildWorker(item.id).doWork()
            assertEquals(
                androidx.work.ListenableWorker.Result
                    .retry(),
                first,
            )
            assertEquals(UploadState.PENDING, db.dao().get(item.id)?.state)
            assertEquals(1, db.dao().get(item.id)?.attempt)

            // 第二次（系統重試）：整條鏈重送一次。
            val second = buildWorker(item.id).doWork()
            assertEquals(
                androidx.work.ListenableWorker.Result
                    .success(),
                second,
            )

            val done = checkNotNull(db.dao().get(item.id))
            assertEquals(UploadState.DONE, done.state)
            assertEquals(2, done.attempt)
            assertEquals("重送只會對應同一個 media id", setOf(item.id), backend.mediaRows.keys)
            assertEquals("重送只會寫到同一組物件路徑", setOf(item.storagePath, item.thumbPath), backend.objectUploads.keys)
            assertEquals(setOf(item.id), backend.attached)
        }

    @Test
    fun quotaExceededFailsTerminallyAndCleansUpOrphanObjects() =
        runBlocking<Unit> {
            val item = queue.enqueue(newId(), familyId, albumId, jpegSource())
            backend.failInsertOnce = BackendError.StorageQuotaExceeded(null)

            val result = buildWorker(item.id).doWork()

            assertTrue("LS002 不可重試", result is androidx.work.ListenableWorker.Result.Failure)
            val failed = checkNotNull(db.dao().get(item.id))
            assertEquals(UploadState.FAILED, failed.state)
            assertEquals("LS002", failed.lastError)
            assertEquals("已上傳的原檔與縮圖是孤兒，要刪掉", listOf(item.storagePath, item.thumbPath), backend.deletedPaths)
            assertTrue(backend.mediaRows.isEmpty())
            assertFalse(File(item.localPath).exists())
        }

    @Test
    fun enqueueingTheSameItemIdTwiceConcurrentlyQueuesOnce() =
        runBlocking<Unit> {
            val id = newId()
            val opened = AtomicInteger()
            val source = jpegSource { opened.incrementAndGet() }

            // 連點兩次「上傳」：同一個 item id 並發入列。
            List(2) { async { queue.enqueue(id, familyId, albumId, source) } }.awaitAll()

            assertEquals("只複製一次來源", 1, opened.get())
            assertEquals(1, db.dao().unfinished().size)
            assertEquals(
                "unique work 只排一筆",
                1,
                workManager.getWorkInfosForUniqueWork(UploadQueue.workName(id)).get().size,
            )
        }

    private fun newId() = UUID.randomUUID().toString()

    private fun jpegSource(onOpen: () -> Unit = {}) =
        UploadSource("image/jpeg") {
            onOpen()
            ByteArrayInputStream(ByteArray(JPEG_BYTES) { it.toByte() })
        }

    private fun buildWorker(itemId: String): UploadWorker =
        TestListenableWorkerBuilder<UploadWorker>(context)
            .setInputData(workDataOf(UploadWorker.KEY_ITEM_ID to itemId))
            .setWorkerFactory(factory)
            .build()

    /** 讓 WorkManager 測試驅動器放行（網路條件滿足）該項目目前排著的 work，回傳執行後的 WorkInfo。 */
    private fun runScheduledWork(itemId: String): WorkInfo {
        val name = UploadQueue.workName(itemId)
        val pending =
            workManager
                .getWorkInfosForUniqueWork(name)
                .get()
                .single { it.state == WorkInfo.State.ENQUEUED }
        checkNotNull(WorkManagerTestInitHelper.getTestDriver(context)).setAllConstraintsMet(pending.id)
        // CoroutineWorker 在 Dispatchers.Default 上跑（SynchronousExecutor 只管 WorkManager 自己的執行緒），所以要等它跑完。
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(WAIT_SECONDS)
        while (System.nanoTime() < deadline) {
            val info = checkNotNull(workManager.getWorkInfoById(pending.id).get())
            if (info.state.isFinished) return info
            Thread.sleep(POLL_MS)
        }
        error("work ${pending.id} 在 ${WAIT_SECONDS}s 內沒跑完")
    }

    private companion object {
        const val JPEG_BYTES = 2048
        const val WAIT_SECONDS = 10L
        const val POLL_MS = 20L
    }
}

/** 模擬伺服器端狀態：media 以主鍵為準（重複 INSERT 不增列，同真實 repository 對 23505 的處理）。 */
private class FakeBackend : MediaUploadBackend {
    val uploadCalls = AtomicInteger()
    val insertCalls = AtomicInteger()
    val attachCalls = AtomicInteger()
    val objectUploads = ConcurrentHashMap<String, Int>()
    val mediaRows = ConcurrentHashMap<String, NewMedia>()
    val attached: MutableSet<String> = ConcurrentHashMap.newKeySet()
    val deletedPaths = mutableListOf<String>()
    var failAttachOnce: BackendError? = null
    var failInsertOnce: BackendError? = null

    override suspend fun uploadFile(
        path: String,
        file: File,
        contentType: String,
    ) = recordUpload(path)

    override suspend fun uploadBytes(
        path: String,
        bytes: ByteArray,
        contentType: String,
    ) = recordUpload(path)

    private fun recordUpload(path: String) {
        uploadCalls.incrementAndGet()
        objectUploads.merge(path, 1, Int::plus)
    }

    override suspend fun insertMedia(media: NewMedia) {
        insertCalls.incrementAndGet()
        failInsertOnce?.let {
            failInsertOnce = null
            throw it
        }
        mediaRows.putIfAbsent(media.id, media)
    }

    override suspend fun attachToAlbum(
        albumId: String,
        familyId: String,
        mediaId: String,
    ) {
        attachCalls.incrementAndGet()
        failAttachOnce?.let {
            failAttachOnce = null
            throw it
        }
        attached.add(mediaId)
    }

    override suspend fun deleteObjects(paths: List<String>) {
        deletedPaths.addAll(paths)
    }
}

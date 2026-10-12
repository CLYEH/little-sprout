package com.clyeh.sproutday

import android.app.Application
import androidx.room.Room
import androidx.work.Configuration
import androidx.work.WorkManager
import com.clyeh.sproutday.push.PushNotifications
import com.clyeh.sproutday.push.PushTokenSync
import com.clyeh.sproutday.supabase.AuthRepository
import com.clyeh.sproutday.supabase.MediaRepository
import com.clyeh.sproutday.supabase.PushRepository
import com.clyeh.sproutday.supabase.SupabaseClientFactory
import com.clyeh.sproutday.upload.AndroidMediaPreparer
import com.clyeh.sproutday.upload.UploadDatabase
import com.clyeh.sproutday.upload.UploadDependencies
import com.clyeh.sproutday.upload.UploadQueue
import com.clyeh.sproutday.upload.UploadWorkerFactory
import io.github.jan.supabase.SupabaseClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class SproutDayApplication :
    Application(),
    Configuration.Provider {
    /** 全 app 共用一個 client（session 持久化與 auto-refresh 都在它身上）；缺 SUPABASE_URL／KEY 時第一次使用就 fail loud。 */
    val supabase: SupabaseClient by lazy { SupabaseClientFactory.create() }

    val mediaRepository: MediaRepository by lazy { MediaRepository(supabase) }

    val pushTokenSync: PushTokenSync by lazy { PushTokenSync(AuthRepository(supabase), PushRepository(supabase)) }

    private val pushSyncStarted = AtomicBoolean(false)

    /** 開始「登入狀態變化就同步 FCM token」；Activity 重建會重複呼叫，只有第一次生效。要在 [supabase] 可用之後呼叫（缺設定時這裡 fail loud）。 */
    fun startPushSync() {
        if (pushSyncStarted.compareAndSet(false, true)) pushTokenSync.start(appScope)
    }

    private val uploadDatabase: UploadDatabase by lazy {
        Room.databaseBuilder(this, UploadDatabase::class.java, "upload-queue.db").build()
    }

    val uploadQueue: UploadQueue by lazy {
        UploadQueue(File(filesDir, "upload-queue"), uploadDatabase.dao(), WorkManager.getInstance(this))
    }

    /** 行程等級的 scope，與 Application 同生共死（不需要也沒有人取消）；用於啟動時補排佇列與推播 token 同步。 */
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** 隨需初始化（取代 androidx.startup 預設初始化）：Worker 由我們的 factory 建立，依賴才注入得進去。 */
    override val workManagerConfiguration: Configuration
        get() =
            Configuration
                .Builder()
                .setWorkerFactory(
                    UploadWorkerFactory(
                        UploadDependencies(uploadDatabase.dao(), lazy { mediaRepository }, AndroidMediaPreparer()),
                    ),
                ).build()

    override fun onCreate() {
        super.onCreate()
        PushNotifications.ensureChannel(this)
        // 行程被殺後重啟：把「有列、沒 work」的未完成項補排回 WorkManager（KEEP，已在排的不受影響）。
        appScope.launch { uploadQueue.resumeAll() }
    }
}

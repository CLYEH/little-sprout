package com.clyeh.sproutday.push

import android.util.Log
import com.clyeh.sproutday.supabase.AuthRepository
import com.clyeh.sproutday.supabase.AuthState
import com.clyeh.sproutday.supabase.BackendError
import com.clyeh.sproutday.supabase.PushRepository
import com.google.android.gms.tasks.Task
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** 取得目前的 FCM registration token；測試／缺 Firebase 設定時可換掉。 */
fun interface FcmTokenSource {
    suspend fun current(): String
}

/**
 * 真正的 [FcmTokenSource]：向 FirebaseMessaging 要 token。**沒有 google-services.json 的 build 沒有 Firebase 設定**
 * （app/build.gradle.kts 缺檔不套 plugin），`getInstance()` 會丟 [IllegalStateException]；它與 Play services
 * 不可用（非 Google APIs 映像）等取不到 token 的情況，都轉成 [BackendError.Misconfigured] fail loud，呼叫端只需處理 [BackendError]。
 */
object FirebaseFcmTokenSource : FcmTokenSource {
    // DEPRECATION：firebase-messaging 26 把 getToken() 標為 deprecated（新的 register()／onRegistered 是 manifest opt-in，預設關閉，
    // 後端 FcmProvider 也只認 registration token），先沿用 getToken()。Task 失敗可能是任何 Exception：取消先重拋，其餘統一轉成 Misconfigured。
    @Suppress("TooGenericExceptionCaught", "DEPRECATION")
    override suspend fun current(): String =
        try {
            FirebaseMessaging.getInstance().token.await()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw BackendError.Misconfigured(
                "取得 FCM token 失敗（沒有 google-services.json，或裝置沒有 Google Play services）：${e.message}",
                e,
            )
        }
}

private suspend fun <T> Task<T>.await(): T =
    suspendCancellableCoroutine { cont ->
        addOnSuccessListener { cont.resume(it) }
        addOnFailureListener { cont.resumeWithException(it) }
        addOnCanceledListener { cont.cancel() }
    }

/**
 * 把本機的 FCM token 同步到 `device_tokens`（`register_device_token`，platform=android）。
 *
 * - 登入成功（[AuthState.SignedIn] 變化，含換帳號）時，**重新向 FCM 要目前的 token** 再註冊：token 不隨帳號變動，換帳號後必須由新帳號重新註冊
 *   才會把 `device_tokens` 那一列接手過來（見 [PushRepository]）；所以不另外「暫存 onNewToken」——token 的唯一真相在 FirebaseMessaging，
 *   登入後重取，沒有 session 時刷新的 token 也自然被涵蓋。
 * - [onTokenRefreshed]（`FirebaseMessagingService.onNewToken`）：等 session 載入完成（冷啟動時是 Initializing）；已登入就註冊，未登入略過。
 * - 註冊失敗只記 log、**不重試迴圈**；下一次登入狀態變化、App 重開或 token 刷新會再送。RPC 冪等（同 token 列數不變），多條觸發路徑
 *   重疊只是多送一次。
 */
class PushTokenSync(
    private val auth: AuthRepository,
    private val push: PushRepository,
    private val tokens: FcmTokenSource = FirebaseFcmTokenSource,
) {
    /** 註冊目前的 FCM token 並回傳它（除錯面板用）。失敗丟 [BackendError]。 */
    suspend fun registerCurrentToken(): String {
        val token = tokens.current()
        push.registerDeviceToken(token)
        return token
    }

    /**
     * 之後每次登入狀態變化（含換帳號）就同步一次。[scope] 由呼叫端（Application 的行程 scope）擁有，與行程同生共死；
     * 新的登入狀態會取消上一輪還沒做完的同步（`collectLatest`）。
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun start(scope: CoroutineScope) {
        scope.launch {
            auth.authState.distinctUntilChanged().collectLatest { state ->
                if (state is AuthState.SignedIn) logFailure { registerCurrentToken() }
            }
        }
    }

    /** `onNewToken`：已登入才註冊 [token]（等 session 載入完成再判斷）；在 [scope] 內非同步進行，不阻塞 service 回呼。 */
    fun onTokenRefreshed(
        scope: CoroutineScope,
        token: String,
    ) {
        scope.launch {
            val state = auth.authState.first { it !is AuthState.Initializing }
            if (state is AuthState.SignedIn) logFailure { push.registerDeviceToken(token) }
        }
    }

    private suspend fun logFailure(block: suspend () -> Unit) {
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: BackendError) {
            Log.w(TAG, "推播 token 註冊失敗（不重試，下次登入狀態變化或 token 刷新再送）：[${e.code ?: "-"}] ${e.message}")
        }
    }

    private companion object {
        const val TAG = "SproutDayPush"
    }
}

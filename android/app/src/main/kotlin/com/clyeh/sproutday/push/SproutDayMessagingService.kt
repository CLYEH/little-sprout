package com.clyeh.sproutday.push

import com.clyeh.sproutday.SproutDayApplication
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * FCM 入口。`push-dispatch` 送的訊息只有 `notification { title, body }`（supabase/functions/push-dispatch/fcm.ts，沒有 data 欄位）：
 * 背景時 SDK 自己顯示、不會呼叫 [onMessageReceived]；前景時才進來，這裡補顯示通知。
 */
class SproutDayMessagingService : FirebaseMessagingService() {
    private val app get() = application as SproutDayApplication

    // firebase-messaging 26 標 onNewToken deprecated（新路徑 onRegistered 是 opt-in）；理由見 FirebaseFcmTokenSource
    @Suppress("OVERRIDE_DEPRECATION")
    override fun onNewToken(token: String) {
        app.pushTokenSync.onTokenRefreshed(app.appScope, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val notification = message.notification ?: return // data-only 訊息目前不存在（fcm.ts 不送），先不處理
        if (!PushNotifications.isAppInForeground()) return
        PushNotifications.show(
            this,
            notification.title,
            notification.body,
            message.messageId ?: System.nanoTime().toString(),
        )
    }
}

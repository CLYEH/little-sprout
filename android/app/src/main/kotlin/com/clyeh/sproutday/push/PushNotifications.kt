package com.clyeh.sproutday.push

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.NotificationCompat
import com.clyeh.sproutday.MainActivity

/** 通知 channel 與前景通知顯示。背景時 FCM SDK 會自己把 notification 訊息顯示在系統列（用 manifest 指定的預設 channel），不經過這裡。 */
object PushNotifications {
    /** 與 AndroidManifest 的 `default_notification_channel_id` meta-data 同值（背景由 SDK 顯示的通知也落在這個 channel）。 */
    const val CHANNEL_ID = "sprout_day_default"

    private const val TAG = "SproutDayPush"

    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Sprout Day 通知", NotificationManager.IMPORTANCE_DEFAULT),
        )
    }

    /** App 是否在前景（`onMessageReceived` 只在前景才自己建通知；背景交給 SDK，避免重複）。 */
    fun isAppInForeground(): Boolean {
        val info = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(info)
        return info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    /**
     * 顯示一則通知；通知權限（API 33+ `POST_NOTIFICATIONS`）或 channel 被使用者關閉時只記 log、不丟例外。
     * [dedupKey] 相同（同一個 FCM messageId 重送）會覆蓋同一則，不會疊出兩則。
     */
    fun show(
        context: Context,
        title: String?,
        body: String?,
        dedupKey: String,
    ) {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled()) {
            Log.w(TAG, "通知權限未授予（或已被關閉），略過顯示：$title")
            return
        }
        ensureChannel(context)
        val open =
            PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        val notification =
            NotificationCompat
                .Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .setContentIntent(open)
                .build()
        manager.notify(dedupKey.hashCode(), notification)
    }
}

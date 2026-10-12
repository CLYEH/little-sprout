package com.clyeh.sproutday

import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import io.github.jan.supabase.auth.handleDeeplinks

class MainActivity : ComponentActivity() {
    private val supabase get() = (application as SproutDayApplication).supabase

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 只在「全新啟動」處理：旋轉／行程還原重建時 getIntent() 仍是當初的 callback intent，重複處理會白做一次注定失敗的 code 交換。
        // 冷啟動就是從 sproutday://auth/callback 進來（行程在 Custom Tab 期間被系統回收）的情況仍涵蓋。
        if (savedInstanceState == null) handleAuthCallback(intent)
        (application as SproutDayApplication).startPushSync()
        setContent {
            MaterialTheme {
                RootContent(supabase)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleAuthCallback(intent)
    }

    /** Apple OAuth（PKCE）：Custom Tab 導回 sproutday://auth/callback?code=… → 換 session，結果走 authState；失敗記 log、不吞。 */
    private fun handleAuthCallback(intent: Intent) {
        supabase.handleDeeplinks(intent, onError = { Log.e(TAG, "auth callback 處理失敗", it) })
    }

    private companion object {
        const val TAG = "SproutDayAuth"
    }
}

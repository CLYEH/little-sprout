package com.clyeh.sproutday

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.lifecycle.viewmodel.compose.viewModel
import com.clyeh.sproutday.debug.DebugAuthPanel
import com.clyeh.sproutday.debug.DebugAuthViewModel
import com.clyeh.sproutday.supabase.AuthRepository
import com.clyeh.sproutday.supabase.FamilyRepository
import io.github.jan.supabase.auth.handleDeeplinks

class MainActivity : ComponentActivity() {
    private val supabase get() = (application as SproutDayApplication).supabase

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 冷啟動就是從 sproutday://auth/callback 進來的情況（行程在 Custom Tab 期間被系統回收）
        supabase.handleDeeplinks(intent)
        setContent {
            MaterialTheme {
                val vm: DebugAuthViewModel =
                    viewModel(
                        factory =
                            DebugAuthViewModel.factory(
                                AuthRepository(supabase),
                                FamilyRepository(supabase),
                            ),
                    )
                DebugAuthPanel(vm)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Apple OAuth（PKCE）：Custom Tab 導回 sproutday://auth/callback?code=… → 換 session，結果走 authState
        supabase.handleDeeplinks(intent)
    }
}

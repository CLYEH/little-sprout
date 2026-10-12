package com.clyeh.sproutday

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewmodel.compose.viewModel
import com.clyeh.sproutday.debug.DebugAuthPanel
import com.clyeh.sproutday.debug.DebugAuthViewModel
import com.clyeh.sproutday.supabase.AuthRepository
import com.clyeh.sproutday.supabase.ChildrenRepository
import com.clyeh.sproutday.supabase.DiaryRepository
import com.clyeh.sproutday.supabase.FamilyRepository
import com.clyeh.sproutday.supabase.FeedRepository
import com.clyeh.sproutday.supabase.FoodRepository
import com.clyeh.sproutday.supabase.GrowthRepository
import com.clyeh.sproutday.supabase.SocialRepository
import io.github.jan.supabase.SupabaseClient

/** debug 建置的根畫面＝除錯登入面板（LS-479）；release 的同名函式在 src/release，不含任何除錯類別。 */
@Composable
fun RootContent(supabase: SupabaseClient) {
    val app = LocalContext.current.applicationContext as SproutDayApplication
    val vm: DebugAuthViewModel =
        viewModel(
            factory =
                DebugAuthViewModel.factory(
                    AuthRepository(supabase),
                    FamilyRepository(supabase),
                    app.mediaRepository,
                    app.uploadQueue,
                    FeedRepository(supabase),
                    SocialRepository(supabase),
                    ChildrenRepository(supabase),
                    GrowthRepository(supabase),
                    FoodRepository(supabase),
                    DiaryRepository(supabase),
                    app.pushTokenSync,
                ),
        )
    DebugAuthPanel(vm)
}

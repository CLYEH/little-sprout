package com.clyeh.sproutday

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable

/**
 * 骨架階段（LS-474）唯一的畫面；畫面票到了會被真正的首頁取代。
 * 畫面 composable 一律命名 `*Screen`——LS-478 的 48dp 登記制（scripts/gates/android-tap-target-registry-check.sh）
 * 以此為準：每個 `*Screen` 要嘛登記進 androidTest 的 `TapTargetGateScreens`，要嘛在 `android/tap-target-exemptions.txt` 具名排除。
 */
@Composable
internal fun HomeScreen() {
    Text(text = "Sprout Day")
}

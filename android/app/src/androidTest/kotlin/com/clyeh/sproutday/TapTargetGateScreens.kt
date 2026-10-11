package com.clyeh.sproutday

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable

/**
 * 一個登記進 48dp 點擊目標 gate 的畫面（LS-478；iOS 對應物：`TapTargetGateScreenName` 註冊表）。
 *
 * @param name 必須等於 composable 的函式名（`*Screen`）——scripts/gates/android-tap-target-registry-check.sh
 *   以這個字串對帳 `android/app` 主程式碼的 `*Screen`。
 * @param minClickables 這個畫面（免登入、免假資料的預設狀態）至少要有幾個可點節點。0＝目前沒有可互動元件；
 *   畫面長出按鈕後把它調高，之後有人拿掉按鈕 gate 會紅，不會靜默變成空跑。
 * @param content 以 [MaterialTheme] 包起來渲染該畫面（畫面需要 ViewModel／網路才建得起來的，不登記，改進 exemptions 並寫理由）。
 */
class TapTargetScreen(
    val name: String,
    val minClickables: Int,
    val content: @Composable () -> Unit,
) {
    override fun toString(): String = name
}

object TapTargetGateScreens {
    val all: List<TapTargetScreen> =
        listOf(
            TapTargetScreen(name = "HomeScreen", minClickables = 0) { MaterialTheme { HomeScreen() } },
        )
}

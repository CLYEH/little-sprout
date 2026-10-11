package com.clyeh.sproutday

import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.unit.dp

/**
 * 對目前 setContent 的內容，量每一個可點節點（合併語意樹）所在 LayoutNode 的尺寸 ≥48dp×48dp（長輩約束；iOS 是 44pt）。
 *
 * 為什麼量 `layoutInfo` 而不是 `touchBoundsInRoot`／`assertTouchHeightIsEqualTo`：Compose 對任何帶 OnClick 語意的節點，
 * 會把 `touchBoundsInRoot` 自動擴到 ViewConfiguration 的最小觸控尺寸（預設 48dp），所以拿它比 48dp 永遠過、gate 形同空跑
 * （Compose 1.11 的 ui-test 也沒有 `assertTouchHeightIsAtLeast`）。`layoutInfo` 是該節點整條 modifier 鏈量完的尺寸，
 * 包含 `minimumInteractiveComponentSize()` 與明確的 `heightIn(min = 48.dp)`／`size`，不含框架的隱形擴張——
 * 這正是專案規約要求 app 自己保證的那一份；裸 `Modifier.clickable` 的 20dp 方塊會被抓到。
 *
 * 紅時訊息點名畫面、第幾個可點節點與實測 dp。
 */
fun ComposeContentTestRule.assertClickablesMeetMinTouchTarget(
    screenName: String,
    minClickables: Int,
) {
    val count = onAllNodes(hasClickAction()).fetchSemanticsNodes().size
    if (count < minClickables) {
        throw AssertionError("[$screenName] 預期至少 $minClickables 個可點節點，實得 $count（畫面改了卻沒同步調整登記？）")
    }
    for (i in 0 until count) {
        val info = onAllNodes(hasClickAction())[i].fetchSemanticsNode().layoutInfo
        with(info.density) {
            val minPx = MIN_TOUCH_DP.dp.toPx()
            // 1px 容差：48dp 在非整數密度下 roundToPx 可能少半個 px，不該因此誤報。
            if (info.width + ROUNDING_PX < minPx || info.height + ROUNDING_PX < minPx) {
                val w = info.width.toDp().value
                val h = info.height.toDp().value
                throw AssertionError("[$screenName] 第 $i 個可點節點尺寸 ${w}dp x ${h}dp，小於 ${MIN_TOUCH_DP}dp")
            }
        }
    }
}

private const val MIN_TOUCH_DP = 48
private const val ROUNDING_PX = 1f

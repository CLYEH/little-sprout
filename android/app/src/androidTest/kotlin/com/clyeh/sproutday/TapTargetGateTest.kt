package com.clyeh.sproutday

import androidx.compose.ui.test.junit4.createComposeRule
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/** 登記表（[TapTargetGateScreens]）裡的每個畫面各跑一次：所有可點節點觸控區 ≥48dp。 */
@RunWith(Parameterized::class)
class TapTargetGateTest(
    private val screen: TapTargetScreen,
) {
    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun screens(): List<TapTargetScreen> = TapTargetGateScreens.all
    }

    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun everyClickableMeetsMinTouchTarget() {
        composeRule.setContent { screen.content() }
        composeRule.assertClickablesMeetMinTouchTarget(screen.name, screen.minClickables)
    }
}

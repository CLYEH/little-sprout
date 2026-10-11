package com.clyeh.sproutday

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalMinimumInteractiveComponentSize
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * gate 自己的自測（iOS 對應物：`TapTargetGateSelfTests`）：沒有它，登記表目前只有一個零按鈕的畫面，
 * `TapTargetGateTest` 綠不代表量測真的會咬人。負樣本必須紅、正樣本必須綠。
 */
@RunWith(AndroidJUnit4::class)
class TapTargetGateSelfTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun rawClickable20dpIsRejected() {
        composeRule.setContent { Box(Modifier.size(20.dp).clickable(onClick = {})) }
        val error =
            assertThrows(AssertionError::class.java) {
                composeRule.assertClickablesMeetMinTouchTarget("SelfTestTooSmall", minClickables = 1)
            }
        assertTrue("訊息應點名畫面：${error.message}", error.message.orEmpty().contains("SelfTestTooSmall"))
    }

    @Test
    fun materialButtonWithEnforcementDisabledIsRejected() {
        composeRule.setContent {
            CompositionLocalProvider(LocalMinimumInteractiveComponentSize provides 0.dp) {
                Button(onClick = {}, modifier = Modifier.size(24.dp), contentPadding = PaddingValues(0.dp)) {}
            }
        }
        assertThrows(AssertionError::class.java) {
            composeRule.assertClickablesMeetMinTouchTarget("SelfTestEnforcementOff", minClickables = 1)
        }
    }

    @Test
    fun defaultMaterialButtonPasses() {
        composeRule.setContent { Button(onClick = {}) { Text("OK") } }
        composeRule.assertClickablesMeetMinTouchTarget("SelfTestButton", minClickables = 1)
    }

    @Test
    fun smallIconButtonPassesBecauseTouchTargetIsPadded() {
        composeRule.setContent { IconButton(onClick = {}) { Box(Modifier.size(16.dp)) } }
        composeRule.assertClickablesMeetMinTouchTarget("SelfTestIconButton", minClickables = 1)
    }

    @Test
    fun missingClickablesAreRejectedWhenRegistrationExpectsThem() {
        composeRule.setContent { Text("no buttons here") }
        assertThrows(AssertionError::class.java) {
            composeRule.assertClickablesMeetMinTouchTarget("SelfTestNoClickables", minClickables = 1)
        }
    }
}

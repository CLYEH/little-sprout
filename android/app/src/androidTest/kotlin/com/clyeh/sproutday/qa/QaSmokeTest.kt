package com.clyeh.sproutday.qa

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clyeh.sproutday.MainActivity
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * `qa-e2e-android.sh` 的進入點（iOS 對應物：`QASmokeTests`）。只有帶 `LS_QA_SCENARIO` instrumentation arg 時才跑；
 * CI 的全量 `connectedDebugAndroidTest` 不帶，這支以 assumption 略過（報告裡是 skipped，不是綠）；
 * CI 另有一次只跑本類並帶 `LS_QA_SCENARIO=login` 的呼叫，讓 [QaDriver] 每次都在裝置上真跑。
 * rule 負責啟動 [MainActivity]（並強制開啟 Compose 語意樹，原因見 [QaDriver]）。
 */
@RunWith(AndroidJUnit4::class)
class QaSmokeTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun runScenario() {
        val args = InstrumentationRegistry.getArguments()
        val scenario = args.getString("LS_QA_SCENARIO")
        assumeTrue("未帶 LS_QA_SCENARIO（只有 scripts/ops/qa-e2e-android.sh 會帶）", scenario != null)
        QaDriver(requireNotNull(scenario), args, composeRule).run()
    }
}

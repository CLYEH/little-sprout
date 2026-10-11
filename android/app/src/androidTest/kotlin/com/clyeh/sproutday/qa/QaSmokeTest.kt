package com.clyeh.sproutday.qa

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * `qa-e2e-android.sh` 的進入點（iOS 對應物：`QASmokeTests`）。只有帶 `LS_QA_SCENARIO` instrumentation arg 時才跑；
 * CI 的 `connectedDebugAndroidTest` 不帶，這支以 assumption 略過（報告裡是 skipped，不是綠）。
 */
@RunWith(AndroidJUnit4::class)
class QaSmokeTest {
    @Test
    fun runScenario() {
        val args = InstrumentationRegistry.getArguments()
        val scenario = args.getString("LS_QA_SCENARIO")
        assumeTrue("未帶 LS_QA_SCENARIO（只有 scripts/ops/qa-e2e-android.sh 會帶）", scenario != null)
        QaDriver(requireNotNull(scenario), args).run()
    }
}

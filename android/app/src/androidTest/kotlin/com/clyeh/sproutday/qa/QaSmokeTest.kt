package com.clyeh.sproutday.qa

import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
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
 * rule 只負責 Compose 語意樹（原因見 [QaDriver]）；[MainActivity] 在 assumption 之後才手動啟動——MainActivity 一啟動就建 Supabase client，
 * 沒有 local.properties 的環境（CI 全量 connected、push gate）會 crash，不能在略過的情境也先起它（LS-479 合併後）。
 */
@RunWith(AndroidJUnit4::class)
class QaSmokeTest {
    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun runScenario() {
        val args = InstrumentationRegistry.getArguments()
        val scenario = args.getString("LS_QA_SCENARIO")
        assumeTrue("未帶 LS_QA_SCENARIO（只有 scripts/ops/qa-e2e-android.sh 會帶）", scenario != null)
        ActivityScenario.launch(MainActivity::class.java).use {
            QaDriver(requireNotNull(scenario), args, composeRule).run()
        }
    }
}

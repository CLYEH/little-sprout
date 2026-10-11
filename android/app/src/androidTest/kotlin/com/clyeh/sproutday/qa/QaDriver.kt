package com.clyeh.sproutday.qa

import android.os.Bundle
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import java.io.File

/**
 * QA 端到端情境驅動（LS-478；iOS 對應物：`LittleSproutUITests/QA/QADriver`）。由 `scripts/ops/qa-e2e-android.sh` 以
 * `am instrument -e LS_QA_SCENARIO <login|publish|browse>` 驅動，對本機 Supabase 容器（emulator 內用 10.0.2.2 連宿主機）實跑。
 *
 * **分工：App 內畫面用 Compose 語意節點查（[composeRule]），系統層（截圖、系統對話框、Home）用 UiAutomator（[UiDevice]）。**
 * 不能用 UiAutomator 的 `By.text` 找 Compose 文字：`am instrument` 讓測試跑在被測 app 的行程內，Compose 只在
 * `AccessibilityManager.getEnabledAccessibilityServiceList()` 非空時才建語意樹，而該情境下它是空的——視窗階層裡根本沒有 ComposeView
 * （LS-478 R2 在 API 36 emulator 實跑才現形：首頁文字肉眼可見、`By.text` 15 秒找不到）。`createAndroidComposeRule` 會強制開啟語意樹。
 *
 * 目前 app 只有骨架（`HomeScreen`），所以：
 * - `login` 只走到「app 冷啟動（script 每次先 `pm clear`）、首頁文字可見」，並把 script 帶進來的種子（API URL／Mailpit／信箱；
 *   不含 anon key）落成 config.txt，證明 instrumentation args 真的到了裝置端。
 * - `publish`／`browse` 是骨架：先跑到同一個起點，再 **fail loud**（AssertionError）——沒有畫面可走卻回通過，
 *   等於 QA 拿到一個假綠。畫面票（登入、新增回憶、時間軸…）到了再把 TODO 補成真步驟。
 *
 * 截圖落在**被測 app** 的 external files dir（`/sdcard/Android/data/com.clyeh.sproutday/files/qa-e2e/<情境>/`），script 結束後 `adb pull`。
 * 不能用測試 APK 的目錄：測試以被測 app 的 UID 跑，`instrumentation.context.getExternalFilesDir()` 要 mkdirs
 * `…/com.clyeh.sproutday.test/files` 會被 StorageManager 以「does not contain calling package com.clyeh.sproutday」拒絕而回 null。
 */
class QaDriver(
    private val scenario: String,
    private val args: Bundle,
    private val composeRule: ComposeTestRule,
) {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)
    private val outDir =
        File(
            requireNotNull(instrumentation.targetContext.getExternalFilesDir(null)) { "被測 app 沒有 external files dir" },
            "qa-e2e/$scenario",
        )
    private var stepNo = 0

    fun run() {
        check(scenario in SCENARIOS) { "未知情境「$scenario」，合法：${SCENARIOS.joinToString("|")}" }
        outDir.deleteRecursively()
        check(outDir.mkdirs()) { "建不出截圖目錄 $outDir" }
        writeConfig()
        awaitHome()
        snap("launch")
        when (scenario) {
            "login" -> login()
            else -> throw AssertionError("情境 $scenario 尚未實作：app 目前只有骨架首頁，等對應的畫面票")
        }
    }

    private fun login() {
        // TODO(登入畫面票)：歡迎頁 → Email → 自 Mailpit 取 6 碼（LS_QA_MAILPIT）→ 確認登入 → 落點。現在只驗冷啟動可達。
        snap("home")
    }

    private fun awaitHome() {
        try {
            composeRule.waitUntil(LAUNCH_TIMEOUT_MS) {
                composeRule.onAllNodesWithText(HOME_TEXT, substring = true).fetchSemanticsNodes().isNotEmpty()
            }
        } catch (e: ComposeTimeoutException) {
            // 不吞：補一張失敗當下的截圖再原樣重拋，證據目錄裡看得到 app 到底停在哪。
            device.takeScreenshot(File(outDir, "$scenario-00-await-home-timeout.png"))
            throw AssertionError("冷啟動後 ${LAUNCH_TIMEOUT_MS}ms 內看不到首頁文字「$HOME_TEXT」", e)
        }
    }

    /** 檔名 `<情境>-<序號>-<步驟>.png`，同 iOS QADriver.snap 的命名，script 直接收進 screens/。 */
    private fun snap(step: String) {
        stepNo += 1
        val file = File(outDir, "%s-%02d-%s.png".format(scenario, stepNo, step))
        check(device.takeScreenshot(file)) { "截圖失敗：$file" }
    }

    private fun writeConfig() {
        // 不寫 LS_QA_ANON_KEY：證據目錄會被貼進票 comment／PR，金鑰不該跟著走。
        val keys = listOf("LS_QA_API_URL", "LS_QA_MAILPIT", "LS_QA_EMAIL")
        val lines = keys.joinToString("\n") { "$it=${args.getString(it).orEmpty()}" }
        File(outDir, "config.txt").writeText(lines + "\n")
    }

    private companion object {
        val SCENARIOS = listOf("login", "publish", "browse")

        // 子字串比對：release 根畫面是「Sprout Day」、debug 根畫面是「Sprout Day — 除錯登入面板」（LS-479），兩種建置都要過。
        const val HOME_TEXT = "Sprout Day"
        const val LAUNCH_TIMEOUT_MS = 15_000L
    }
}

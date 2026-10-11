package com.clyeh.sproutday.qa

import android.content.Intent
import android.os.Bundle
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import java.io.File

/**
 * QA 端到端情境驅動（LS-478；iOS 對應物：`LittleSproutUITests/QA/QADriver`）。由 `scripts/ops/qa-e2e-android.sh` 以
 * `am instrument -e LS_QA_SCENARIO <login|publish|browse>` 驅動，對本機 Supabase 容器（emulator 內用 10.0.2.2 連宿主機）實跑。
 *
 * 目前 app 只有骨架（`HomeScreen`），所以：
 * - `login` 只走到「app 冷啟動、首頁文字可見」，並把 script 帶進來的種子（API URL／Mailpit／信箱；不含 anon key）落成 config.txt，
 *   證明 instrumentation args 真的到了裝置端。
 * - `publish`／`browse` 是骨架：先跑到同一個起點，再 **fail loud**（AssertionError）——沒有畫面可走卻回通過，
 *   等於 QA 拿到一個假綠。畫面票（登入、新增回憶、時間軸…）到了再把 TODO 補成真步驟。
 *
 * 截圖落在 instrumentation 自己的 external files dir（`/sdcard/Android/data/<test pkg>/files/qa-e2e/<情境>/`，
 * 不是被測 app 的目錄——API 30+ 的 scoped storage 不讓測試行程寫別的 package），script 結束後 `adb pull`。
 */
class QaDriver(
    private val scenario: String,
    private val args: Bundle,
) {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)
    private val targetContext = instrumentation.targetContext
    private val outDir =
        File(
            requireNotNull(instrumentation.context.getExternalFilesDir(null)) { "測試 app 沒有 external files dir" },
            "qa-e2e/$scenario",
        )
    private var stepNo = 0

    fun run() {
        check(scenario in SCENARIOS) { "未知情境「$scenario」，合法：${SCENARIOS.joinToString("|")}" }
        outDir.deleteRecursively()
        check(outDir.mkdirs()) { "建不出截圖目錄 $outDir" }
        writeConfig()
        launchApp()
        snap("launch")
        when (scenario) {
            "login" -> login()
            else -> throw AssertionError("情境 $scenario 尚未實作：app 目前只有骨架首頁，等對應的畫面票")
        }
    }

    private fun login() {
        // TODO(登入畫面票)：歡迎頁 → Email → 自 Mailpit 取 6 碼（LS_QA_MAILPIT）→ 確認登入 → 落點。現在只驗冷啟動可達。
        check(device.wait(Until.hasObject(By.text(HOME_TEXT)), LAUNCH_TIMEOUT_MS)) {
            "冷啟動後 ${LAUNCH_TIMEOUT_MS}ms 內看不到首頁文字「$HOME_TEXT」"
        }
        snap("home")
    }

    private fun launchApp() {
        device.pressHome()
        val intent =
            requireNotNull(targetContext.packageManager.getLaunchIntentForPackage(targetContext.packageName)) {
                "找不到 ${targetContext.packageName} 的 launcher intent"
            }
        intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)
        targetContext.startActivity(intent)
        check(device.wait(Until.hasObject(By.pkg(targetContext.packageName).depth(0)), LAUNCH_TIMEOUT_MS)) {
            "app ${targetContext.packageName} ${LAUNCH_TIMEOUT_MS}ms 內沒有出現在前景"
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
        const val HOME_TEXT = "Sprout Day"
        const val LAUNCH_TIMEOUT_MS = 15_000L
    }
}

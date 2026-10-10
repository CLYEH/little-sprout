import Foundation

/// LS-458（LS-413 池 P1 `e0f65a8f`／`f608d582`／`def25a8f`）：UITest 等待 timeout 的單一來源。
///
/// 為什麼不寫字面值：CI 慢 runner 上單次 accessibility 快照可以吃到 5–15 秒（LS-268 量到 ~4.5s；LS-458 從
/// ci-ipad run 38008119531 的 log 量到 `Find the "隱藏側邊欄" Button` 單步 9–10s），字面值 5 秒的 `waitFor…`
/// 在那種 runner 上只取得一兩次樣本、等於沒等——每例耗一輪 rerun 17–25 分。規範全文見
/// `docs/COLLABORATION.md` §7「UITest 等待紀律」，`scripts/gates/uitest-wait-check.sh` 抓兩型靜態形狀。
///
/// 慢 runner 判定：環境變數 `LS_UITEST_SLOW_RUNNER=1`。XCUITest 的測試 runner 行程**不會**繼承 xcodebuild 的環境，
/// 只有帶 `TEST_RUNNER_` 前綴的變數會被剝掉前綴傳進來——所以 CI 在 `ci.yml` 頂層設
/// `TEST_RUNNER_LS_UITEST_SLOW_RUNNER: "1"`（push-gate／本機不設，維持 5 秒）。
enum UITestTimeouts {
    /// 一般「等某元素出現／消失／可點」的上限：本機 5 秒、慢 runner 10 秒。
    static let standard: TimeInterval = isSlowRunner ? 10 : 5

    private static let isSlowRunner: Bool = ProcessInfo.processInfo.environment["LS_UITEST_SLOW_RUNNER"] == "1"
}

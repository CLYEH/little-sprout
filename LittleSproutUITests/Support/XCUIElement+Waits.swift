import XCTest

/// LS-263（池 `11494a69`，merge-review R1 m1／R2 復核）：`waitForHittable`／
/// `waitForNonExistence` 原本在 `ContentActionsUITests`／`DiaryDetailCommentsUITests`／
/// `SettingsViewIPadTests`／`DiaryDetailVideoUITests`／`SettingsViewTests` 五個檔案各自複製
/// 一份（LS-253／259／261 三票各自照抄）——逐字比對過全部複本，實作完全相同（無 timeout
/// 預設值、同一套 `XCTNSPredicateExpectation` + `XCTWaiter().wait` 輪詢寫法，沿 LS-253
/// `7b493a8` 版），抽成單一 `XCUIElement` extension，各呼叫點改成方法呼叫語法。
extension XCUIElement {
    /// 等到元素 `hittable == true`——`.exists`／`waitForExistence` 只確認元素在
    /// accessibility tree 上，不保證此刻真的可點；tap 前用這個當同步點比較貼近真實使用者操作
    /// （LS-237 第 8 項教訓）。
    ///
    /// LS-265：原本用 `XCTNSPredicateExpectation(predicate: "hittable == true")` 交給
    /// XCTest 內建輪詢——某次取樣恰好落在 nav 轉場中段、元素 `frame` 暫時無效時，XCUITest
    /// 對 `hittable` 求值會直接框架硬失敗（"Activation point invalid and no suggested hit
    /// points based on element frame"），不會像正常情況一樣回 `false` 讓 expectation 繼續等，
    /// 造成「非 timeout」的硬紅（iPad settings push→back 系列同類紅第 6 次）。改成自己控制的
    /// 輪詢迴圈：每次取樣先看 `exists`、再看 `frame` 是否有效（非零大小、非 NaN／非 Infinite），
    /// 都通過才去讀 `isHittable`——避免在 frame 暫時無效的瞬間去觸發那個框架內部求值路徑；任一
    /// 步不成立就當作「尚未就緒」，留到下一次取樣，直到 timeout。回傳型別與預設 timeout 語意
    /// 不變，呼叫端零改動。
    ///
    /// `pollInterval` 只給測試用（重現／驗證用），正常呼叫一律用預設值。
    func waitForHittable(timeout: TimeInterval, pollInterval: TimeInterval = 0.25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isSafelyHittable {
                return true
            }
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: min(pollInterval, max(deadline.timeIntervalSinceNow, 0)))
        }
    }

    /// `waitForHittable` 的取樣前置檢查：只有 `exists` 且 `frame` 看起來有效時才去讀
    /// `isHittable`——`frame` 在轉場中段可能暫時是零大小或含 NaN／Infinite 分量，此時讀
    /// `isHittable` 就是 LS-265 觸發框架硬失敗的路徑。
    private var isSafelyHittable: Bool {
        guard exists else { return false }
        let candidateFrame = frame
        guard
            candidateFrame.width > 0, candidateFrame.height > 0,
            candidateFrame.origin.x.isFinite, candidateFrame.origin.y.isFinite,
            candidateFrame.size.width.isFinite, candidateFrame.size.height.isFinite
        else {
            return false
        }
        return isHittable
    }

    /// 等到元素不再存在——XCTest 沒有內建 `waitForExistence` 的反向版本，一次性 `.exists`
    /// 快照在轉場／dismiss 動畫還沒跑完的瞬間可能誤判成「還在」，用輪詢式 expectation 較可靠
    /// （LS-237 第 8 項教訓）。
    ///
    /// LS-265 風險評估：`exists` 只查 accessibility tree 上有沒有這個節點，不像 `hittable`
    /// 需要框架另外算 activation point／hit-test，沒有觀察到、也沒有理論上的同型「frame 暫時
    /// 無效就框架硬失敗」風險，維持原本的 `XCTNSPredicateExpectation` 寫法不動。
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

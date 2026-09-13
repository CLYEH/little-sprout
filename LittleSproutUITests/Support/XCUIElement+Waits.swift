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
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// 等到元素不再存在——XCTest 沒有內建 `waitForExistence` 的反向版本，一次性 `.exists`
    /// 快照在轉場／dismiss 動畫還沒跑完的瞬間可能誤判成「還在」，用輪詢式 expectation 較可靠
    /// （LS-237 第 8 項教訓）。
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

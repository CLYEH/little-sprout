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
    /// LS-265（merge-review R1 m1 訂正根因敘述）：某次取樣恰好落在 nav 轉場中段、元素
    /// `frame` 暫時無效時會框架硬失敗（"Activation point invalid and no suggested hit
    /// points based on element frame"），不回 `false` 讓輪詢繼續（iPad settings
    /// push→back 系列同類紅第 6 次）。**真正的根因在 `-[XCUIElement isHittable]` 這個
    /// getter 自己內部**：它會呼叫 `hitPoint:`，算不出來就自行記錄硬失敗——原本用
    /// `XCTNSPredicateExpectation(predicate: "hittable == true")` 只是透過 KVC 打到同一個
    /// getter，換掉 expectation、改手寫迴圈本身不是修法重點；真正有效的是「呼叫
    /// `isHittable` 前先驗過 frame 有效」（見 `isSafelyHittable`）——改手寫迴圈只是為了能
    /// 插入這個前置檢查，`XCTNSPredicateExpectation` 沒有插入前置條件的入口。任一步不成立
    /// 就當作「尚未就緒」，留到下一次取樣，直到 timeout。回傳型別與 timeout 語意不變，
    /// 呼叫端（`SettingsViewIPadTests` 7 處、`DiaryDetailVideoUITests` 2 處、
    /// `SettingsViewTests` 2 處，共 3 檔 11 處）零改動——**LS-268 例外**：11 處呼叫點的
    /// timeout 值本身從 5s 升到 10s（見下方風險段訂正），呼叫語法不動。
    ///
    /// **LS-268（池 `e6ce0b1b` i2，merge-review R2 informational）**：CI 單次
    /// accessibility 快照實測 ~4.5s，5s 的 timeout 只取得約 2 次樣本、餘裕太薄——11 處呼叫點
    /// 已全部從 5s 升到 10s（風險段以下訂正為實數）。
    ///
    /// 已知風險（merge-review R1 M2，未在本票處理）：CI 慢 runner 上量到單次
    /// `isSafelyHittable` 取樣（快照＋`isHittable`）可能吃掉 4.5s，11 處呼叫點的 timeout
    /// 現皆為 10s——那種 runner 上，本輪迴圈仍可能連一輪完整取樣都做不完就
    /// timeout，把「框架硬失敗」換成「逾時斷言紅」而非變綠。這是呼叫端 timeout 預算問題，
    /// 票文明訂「呼叫點改動不在本票」，此處只記錄風險，不動呼叫點。
    ///
    /// **LS-268（池 `e6ce0b1b` m1，`visibleFrame` 缺口）**：`isSafelyHittable` 只驗證
    /// `frame` 非空、座標為有限值，不驗證元素是否落在螢幕／可視範圍內——若元素 `frame` 本身
    /// 合法（寬高 >0、非 NaN／Infinite）但整塊被父容器或螢幕邊界裁切到不可視（例如捲動超出
    /// `visibleFrame`），這個前置檢查仍會放行去問 `isHittable`，而 XCUITest 對「frame 合法
    /// 但被完全裁切」的元素呼叫 `isHittable` 一樣可能撞上與 LS-265 同款的框架硬失敗（`hitPoint:`
    /// 算不出來）。目前 11 處呼叫端皆搭配捲動到可視範圍的既有邏輯（`scrollUntilAllHittable`
    /// 一類），實務未觀察到這個缺口被觸發，記錄於此供下次同型故障排查時參考，不在本票新增
    /// `visibleFrame` 檢查（未被要求的防禦性程式碼，CLAUDE.md Rule 2）。
    ///
    /// i2（merge-review R1 informational，評估後不採用）：曾考慮要求連續兩次取樣 frame
    /// 都有效才問 `isHittable`，理論上能再降低「snapshot 驗完、緊接著呼叫 `isHittable`
    /// 之間又消失」的窗口。不採用的理由：(1) 這個窗口本來就已經被本票的 `try? snapshot()`
    /// 前置檢查收斂到「同一輪迴圈內」，殘餘窗口是 `isHittable` 自己的獨立呼叫，i2 對它的
    /// 保護是機率性、不是保證；(2) i2 會讓每次呼叫至少多付一個 `pollInterval` 的延遲——即
    /// 使元素從一開始就已經可點，也要等到第二次取樣才會回真——這不是「語意不變」該有的行
    /// 為，且與 merge-review R1 M2 要求的「降低取樣成本」方向相反。若之後同型故障仍伴隨
    /// TOCTOU（而非本次的 `frame` 恆為 `CGRectNull`）再評估。
    ///
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isSafelyHittable {
                return true
            }
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: min(Self.hittablePollInterval, max(deadline.timeIntervalSinceNow, 0)))
        }
    }

    /// merge-review R1 m2：R1 版加了 `pollInterval` 參數但沒有任何呼叫點或測試傳它——票文
    /// 明訂「語意不變、呼叫端零改動」，這是未被要求的可設定性（CLAUDE.md Rule 2），移除，
    /// 要用時再加。
    private static let hittablePollInterval: TimeInterval = 0.5

    /// `waitForHittable` 的取樣前置檢查：只有 `exists` 且 `frame` 看起來有效時才去讀
    /// `isHittable`——`frame` 在轉場中段可能暫時是零大小或含 NaN／Infinite 分量，此時讀
    /// `isHittable` 就是 LS-265 觸發框架硬失敗的路徑。
    private var isSafelyHittable: Bool {
        // merge-review R1 M1：`XCUIElement.exists`／`.frame` 都是會 raise 的 resolve 變體——
        // 元素在兩次查詢之間消失就直接框架硬失敗（實測：對不存在元素讀 `.frame` 拋
        // "Failed to get matching snapshot: No matches found"，exit 65），新 guard 這樣寫等
        // 於自己開一條 R1 想避免的硬失敗路徑。改用 `try? snapshot()`（不會 raise 的版本，
        // 解析不到就回 nil）一次拿到快照，exists／frame 都從同一份快照讀，不再各自單獨呼叫。
        guard let elementSnapshot = try? snapshot() else { return false }
        let candidateFrame = elementSnapshot.frame
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

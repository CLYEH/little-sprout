import XCTest

/// `SettingsViewIPadTests` 的側欄切換 helper 與它專用的追蹤鉤子。
///
/// 為什麼另開一檔：`SettingsViewIPadTests.swift` 在 LS-277 之前就已經**正好** 400 行＝SwiftLint
/// `file_length` 的預設上限（push gate／CI lint 都以 `--strict` 跑，warning 即失敗），本票的重試
/// 迴圈與追蹤鉤子放不進去。切出來的是同一個 class 的 extension（同 target、同檔名前綴），呼叫端
/// 一行都不用改。
extension SettingsViewIPadTests {
    /// LS-277：側欄切換 tap 的總次數上限，與 `maxBackTapAttempts` 同理由、同數字（首次＋最多
    /// 2 次補點）——同一種現象、同一份證據，沒有理由給兩套預算。
    private static let maxSidebarTapAttempts = 3

    /// LS-277：側欄五列的 label。`sidebarSelectionSignature` 與
    /// `testSidebarSelectionIsAccessibleAndDistinguishable` 共用同一份（原本只存在於後者的區域
    /// 變數裡）——追蹤鉤子要跟被驗證的那份清單同源，才不會日後兩邊各自漂移。
    static let sidebarTabLabels = ["個人", "家庭", "內容與安全", "法律", "帳號"]

    /// LS-277 的追蹤鉤子：把「側欄現在選到哪一列」壓成一行字，只在補點路徑記進 `XCTContext`
    /// activity。下次同類紅看這一行就能分辨兩種成因：`Selected=` 仍是原本那一列＝tap 送達但
    /// SwiftUI 選取沒有更新（要查 app 側）；已經換成目標那一列＝選取其實切過去了、紅的是目的段
    /// 內容還沒渲染出來（測試端等待／sentinel 的問題）。
    ///
    /// 選取訊號以 `value`（`SettingsView+Sidebar` 那層的 `.accessibilityValue("已選取")`）為判準，
    /// 不用 `isSelected`——LS-253 merge-review R3 M3 用四組 mutation 證明這個 SwiftUI 組合下
    /// `XCUIElement.isSelected` 與真正驅動選取的狀態無關（見
    /// `testSidebarSelectionIsAccessibleAndDistinguishable` 的文件註解）。`isSelected` 仍一併印出
    /// 當人眼輔助，但不要拿它下判斷。
    ///
    /// 同 `navigationSignature`：一律 `try? snapshot()`（不會 raise 的變體，LS-265 M1），診斷用的
    /// 程式碼不該自己把測試打紅；解析成敗比一併帶出（LS-275 i1，避免「讀不到」被誤讀成「沒選取」）。
    private static func sidebarSelectionSignature(_ app: XCUIApplication) -> String {
        let buttons = app.buttons.allElementsBoundByIndex
        let snapshots = buttons.compactMap { try? $0.snapshot() }
        let parseRatio = "(\(snapshots.count)/\(buttons.count) button)"
        let tabs = snapshots.filter { sidebarTabLabels.contains($0.label) }
        guard !tabs.isEmpty else {
            return "Selected=側欄五列一列都讀不到／\(parseRatio)／appState=\(app.state.rawValue)"
        }
        let selected = tabs.filter { ($0.value as? String) == "已選取" }.map(\.label)
        let detail = tabs
            .map { "\($0.label)(value=\(($0.value as? String) ?? "nil")／isSelected=\($0.isSelected))" }
            .joined(separator: "、")
        let selectedText = selected.isEmpty ? "無" : selected.joined(separator: ",")
        return "Selected=\(selectedText)／tabs=\(detail)／\(parseRatio)／appState=\(app.state.rawValue)"
    }

    /// LS-261：四處「切換 sidebar 分頁 → 等目標列出現」原本各自手刻、timeout 不一致（5s），
    /// 統一成同一個 helper 變體。切分頁本身（`waitForHittable` 那一步）維持既有 5s——真正反覆
    /// 紅過的是「切完分頁後等目標列出現」這一步（09-13 內容與安全、09-14 帳號區「刪除帳號」列
    /// 同一種失敗：忙碌 runner 上單次 accessibility snapshot 偏慢，5s 只夠輪詢 1–2 次），對齊全檔
    /// 「轉場後等待」的 10s 慣例（同 `assertPushThenBackReturnsToList` 的 back 相關等待）。
    ///
    /// LS-277（同類紅：09-15 01:23 #420 run `34874121550` ci-ipad，
    /// `testAccountSectionDeleteRowPushesAndBackReturns` 紅在「切到「帳號」後應該看得到「刪除帳號」
    /// 列」）：把單次 tap 改成與 `assertPushThenBackReturnsToList` 同形的可重試收斂迴圈。那份
    /// xcresult 的覆核結論（時間軸／合成事件 plist／失敗當下 hierarchy／錄影 frame PTS）：
    ///  - **不是側欄過渡態**：失敗當下側欄是完整展開的固定欄（`ScrollView {{0, 0}, {280, 1180}}`），
    ///    五列都在樹上、frame 沒動；tap 前的 `waitForHittable` 也早已回 true。
    ///  - **不是 tap 落點錯、也不是兩個 match**：合成事件是 down（`eventType 1`）＋up
    ///    （`eventType 3`，offset 0.05）於 `(140, 351.5)`，正是「帳號」Button
    ///    `{{0, 328.5}, {280, 46}}` 的正中心；`app.buttons` 當下只有一顆 label 是「帳號」
    ///    （另有一個 label 也叫「帳號」的 **Image**——「個人」列裡的 `person.crop.circle`——但
    ///    `.buttons` 查詢不會命中 image）。
    ///  - **tap 之後完全沒有過渡動畫**：螢幕錄影在 tap 前後 37 秒（frame PTS 62.553 → 99.652）
    ///    連一張新 frame 都沒有、逐像素差 0.000%，連按下去的 highlight 都沒有；同一段時間
    ///    accessibility 快照每輪 40–650ms 正常回應＝app 主執行緒是活的。
    /// 也就是「tap 送達、選取狀態完全沒變」，與 LS-271「back tap 送達但沒 pop」同一機制、不同
    /// 觸發點（成因仍未定，app 側假說見 `assertPushThenBackReturnsToList` 的註解）。因為沒有過渡
    /// 態可等，這裡**不加**「側欄穩定再 tap」前置，只加重試與追蹤鉤子。**這是測試端的韌性措施、
    /// 不是根因修復**：綠但有補點＝同一個現象還在發生（job log grep 得到補點字串）。
    ///
    /// 重試在這裡是安全的：側欄列切換前後都留在樹上，重複點同一列＝把 `selection` 設成同一個值
    /// （no-op），不會像返回鈕那樣「其實已經生效」而讓補點落到別的元件上，所以不需要
    /// `assertPushThenBackReturnsToList` 那個「返回鈕自己消失」的 guard。
    func switchSidebarTab(
        app: XCUIApplication, tabLabel: String, expectedRow: XCUIElement, rowDescription: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let tab = app.buttons[tabLabel]
        XCTAssertTrue(tab.waitForHittable(timeout: 10), "「\(tabLabel)」sidebar 列應該可點擊", file: file, line: line)

        var sidebarTapCount = 0
        var rowAppeared = false
        while !rowAppeared && sidebarTapCount < Self.maxSidebarTapAttempts {
            sidebarTapCount += 1
            if sidebarTapCount > 1 {
                XCTContext.runActivity(
                    named: "LS-277：第 \(sidebarTapCount) 次補點「\(tabLabel)」側欄列（前一次 tap 未生效）"
                ) { _ in }
            }
            tab.tap()
            rowAppeared = expectedRow.waitForExistence(timeout: 10)
            if !rowAppeared {
                // 追蹤鉤子只在「tap 後目的段沒出現」這條失敗路徑觸發，成功路徑零額外成本。
                XCTContext.runActivity(
                    named: "LS-277 追蹤：第 \(sidebarTapCount) 次 tap 後側欄 \(Self.sidebarSelectionSignature(app))"
                ) { _ in }
            }
        }
        XCTAssertTrue(
            rowAppeared,
            "切到「\(tabLabel)」後應該看得到「\(rowDescription)」列（已點側欄 \(sidebarTapCount) 次）",
            file: file, line: line
        )
    }
}

import XCTest

/// merge-review R1 B1（blocker）：iPad（regular 寬度）互動回歸——原本的內層
/// `NavigationSplitView` 疊在外層 `NavigationStack` 裡，讓 `SettingsView` 子樹在 iPad 上全部
/// 按不動（含 base 上原本可用的「邀請家人」）。reviewer 實測是靜態截圖看起來全對、互動全壞
/// ——這裡逐區驗證「至少一個入口能 push、能返回」，全部用真的 `tap()` 操作，不是截圖比對。
///
/// 共用 `TapTargetGateHarness.settingsRegularHost`（`.settingsRegular`，強制
/// `horizontalSizeClass = .regular`，見 `TapTargetGateScreenName.swift`）。
@MainActor
final class SettingsViewIPadTests: XCTestCase {
    /// push 後系統返回鈕的 identifier 恆為 `"BackButton"`（label 會沿用上一頁的
    /// `.navigationTitle`，因區塊而異）——同 `SectionTabBarPushRegressionTests` 的既有理由，
    /// 不用 label 字串比對以免跟畫面上其他文字撞名。
    /// merge-review R4 informational 1：`pushedSentinel` 的等待時間原本跟 `entry`／`backButton`
    /// 共用同一個 5 秒——`testFamilySectionInviteRowRegressionPushesAndBackReturns` 實測 1/6
    /// 會 flake，可疑點是 `InviteFamilyView.onAppear` 觸發的 `refreshLatestInvite()` 這段
    /// async 查詢（即使 `.preview()` stub 立即回傳，仍要走一次 Task 排程＋畫面重新渲染），跟
    /// 其他純同步渲染的目的地畫面（`編輯顯示名稱與頭像尚未推出`／`刪除帳號流程尚未推出`等靜態
    /// 文字）不同調。加一個獨立、預設值不變的 `pushedSentinelTimeout` 參數，只有邀請家人這條
    /// 測試傳長一點的值，其餘呼叫點行為不變。
    private func assertPushThenBackReturnsToList(
        app: XCUIApplication, entry: XCUIElement, pushedSentinel: XCUIElement,
        pushedSentinelTimeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "入口列應該存在才能開始這個情境", file: file, line: line)
        // LS-237 第 8 項（coordinator 追加，`testFamilySectionInviteRowRegressionPushesAndBackReturns`
        // 09-12 run 34693191593 flake）：`waitForExistence` 只確認元素進了 accessibility
        // tree，不保證這一刻真的可點——sidebar 切換到「家庭」的轉場動畫還沒完全穩定時
        // `tap()` 可能落空（沒有真的 push），後續等 `pushedSentinel` 自然逾時。tap 前多等
        // 一次「真的可點」當同步點。
        XCTAssertTrue(waitForHittable(entry, timeout: 5), "入口列應該可點擊", file: file, line: line)
        entry.tap()

        XCTAssertTrue(
            pushedSentinel.waitForExistence(timeout: pushedSentinelTimeout),
            "點入口後應該已經 push 到目的地畫面——iPad 上曾經整個按不動（R1 B1）",
            file: file, line: line
        )
        let backButton = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "push 後應該出現系統返回鈕", file: file, line: line)

        backButton.tap()

        // LS-237 第 8 項：先等目的地畫面的 sentinel 真的消失（`waitForNonExistence`——
        // `.exists` 一次性快照在返回轉場動畫還沒跑完時可能誤判成「還在」），確定返回轉場已經
        // 開始收尾，再等入口列重新出現；比原本「entry 先、pushedSentinel 用一次性快照」的
        // 順序更貼近「返回」這個轉場動畫實際發生的先後。
        XCTAssertTrue(
            waitForNonExistence(pushedSentinel, timeout: 10),
            "返回後不該還看得到目的地畫面的內容", file: file, line: line
        )
        XCTAssertTrue(
            entry.waitForExistence(timeout: 10),
            "返回後應該回到原本的清單、重新看到入口列本身",
            file: file, line: line
        )
    }

    /// `XCTNSPredicateExpectation` 是官方建議用來等 `XCUIElement` 屬性變化的寫法（同
    /// `InteractionRowUITests.testLikeToggleTap_doesNotMoveCommentButton` 既有的「等 label
    /// 變化」寫法）——XCTest 沒有內建 `waitForExistence` 的反向版本（等「停止存在」），這裡跟
    /// `waitForHittable` 一起用同一套輪詢機制補上，比一次性 `.exists`／`.isHittable` 快照可靠
    /// （LS-237 第 8 項）。
    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// LS-261：四處「切換 sidebar 分頁 → 等目標列出現」原本各自手刻、timeout 不一致（5s），
    /// 統一成同一個 helper 變體。切分頁本身（`waitForHittable` 那一步）維持既有 5s——真正反覆
    /// 紅過的是「切完分頁後等目標列出現」這一步（09-13 內容與安全、09-14 帳號區「刪除帳號」列
    /// 同一種失敗：忙碌 runner 上單次 accessibility snapshot 偏慢，5s 只夠輪詢 1–2 次），對齊全檔
    /// 「轉場後等待」的 10s 慣例（同 `assertPushThenBackReturnsToList` 的 back 相關等待）。
    private func switchSidebarTab(
        app: XCUIApplication, tabLabel: String, expectedRow: XCUIElement, rowDescription: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let tab = app.buttons[tabLabel]
        XCTAssertTrue(waitForHittable(tab, timeout: 5), "「\(tabLabel)」sidebar 列應該可點擊", file: file, line: line)
        tab.tap()
        XCTAssertTrue(
            expectedRow.waitForExistence(timeout: 10),
            "切到「\(tabLabel)」後應該看得到「\(rowDescription)」列", file: file, line: line
        )
    }

    /// 預設選取＝個人（`SettingsView.regularSelection` 初值），不需要先點 sidebar。對應
    /// reviewer 原始複現「點『個人』列（`qa.settings.profileRow`）→ 畫面完全沒變」。
    ///
    /// LS-192：`ProfileEditView` 從 LS-188 的 `ContentUnavailableView` 佔位換成正式內容，原本
    /// 斷言的「編輯顯示名稱與頭像尚未推出，敬請期待。」文字已經不存在——sentinel 改用新畫面的
    /// 標題（同 `TapTargetGateScreenName.profileEdit` 的既有 sentinel 選擇）。R2
    /// （merge-review R1 M6）：標題訂正為稿面實際文字「個人資料」。
    func testProfileSectionEntryPushesAndBackReturns() {
        let app = TapTargetMeasurement.launch(.settingsRegular)
        TapTargetMeasurement.assertScreenRendered(.settingsRegular, in: app)

        assertPushThenBackReturnsToList(
            app: app,
            entry: app.buttons[QAAccessibilityID.settingsProfileRow],
            pushedSentinel: app.staticTexts["個人資料"]
        )
    }

    /// base（`6d9e01e`）上原本可用的「邀請家人」在 iPad 上的回歸樣本——reviewer 對照 base 的
    /// repro：「點『邀請家人』→ push 正常」。這裡驗證 R2 修完後 iPad 上依然正常，不是只有
    /// 本 PR 新增的七個入口被顧到、把已經可用的這顆列打壞。
    func testFamilySectionInviteRowRegressionPushesAndBackReturns() {
        let app = TapTargetMeasurement.launch(.settingsRegular)
        TapTargetMeasurement.assertScreenRendered(.settingsRegular, in: app)

        // LS-253（LS-96 i1，sweeper `6c406b6a`）：LS-237 `96734b7` 只在共用 helper
        // `assertPushThenBackReturnsToList` 的入口列 tap 加了「tap 前先等真的可點」同步點，
        // 這裡「家庭」sidebar 切換 tap 當時仍是裸 tap——切換轉場動畫還沒穩定時 tap 可能落空，
        // 後續等「邀請家人」列自然逾時。補上同一套 `waitForHittable` 同步點。
        // LS-261：改走統一的 `switchSidebarTab` helper，等待目標列出現的 timeout 由 5s 對齊 10s。
        switchSidebarTab(
            app: app, tabLabel: "家庭",
            expectedRow: app.buttons[QAAccessibilityID.settingsInviteRow], rowDescription: "邀請家人"
        )

        assertPushThenBackReturnsToList(
            app: app,
            entry: app.buttons[QAAccessibilityID.settingsInviteRow],
            // `InviteFamilyView` 用 `.preview()` FamilyStore（`fetchLatestActiveInvite` 回
            // nil）進場會顯示「產生邀請碼」的空狀態按鈕——這顆按鈕是這個畫面在這個 harness
            // 組合下唯一保證存在、不受競速時序影響的文字。
            pushedSentinel: app.buttons["產生邀請碼"],
            // informational 1：這顆按鈕要等 `onAppear` 觸發的 `refreshLatestInvite()` 跑完
            // 才會出現，比其他目的地畫面多一段 async 排程，5 秒在系統忙碌時偶爾不夠。
            pushedSentinelTimeout: 10
        )
    }

    /// reviewer 原始複現三支之一：「切到『內容與安全』→ 點『儲存空間』→ 沒有 push」。
    func testContentSafetySectionStorageRowPushesAndBackReturns() {
        let app = TapTargetMeasurement.launch(.settingsRegular)
        TapTargetMeasurement.assertScreenRendered(.settingsRegular, in: app)

        // LS-245（池 `2c4bfc80`，merge-review LS-241 R2 `f71f5acc`）：09-13 ci-ipad run
        // 103627867933 在這支測試「切到『內容與安全』後應該看得到『儲存空間』列」那一步紅過
        // 一次、同 SHA 重跑綠：sidebar 切換到「內容與安全」的轉場動畫還沒穩定時 tap 可能落空，
        // 後續等「儲存空間」列自然逾時。LS-237 `96734b7` 實際只在共用 helper
        // `assertPushThenBackReturnsToList` 的入口列 tap 加了「tap 前先等真的可點」同步點——
        // 同檔另外兩支（`testFamilySectionInviteRowRegressionPushesAndBackReturns`／
        // `testLegalSectionRowsOpenAndCloseLegalDocumentSheet`）的 sidebar 切換 tap（分別是
        // `app.buttons["家庭"]`／`app.buttons["法律"]`）並未涵蓋在內，當時仍是裸 tap，由
        // LS-253 補上（見該兩處同步點；LS-96 i1，sweeper `6c406b6a`）。
        // LS-261：改走統一的 `switchSidebarTab` helper，等待目標列出現的 timeout 由 5s 對齊 10s——
        // 這正是 LS-245 池 `2c4bfc80` 紅過的那一步（忙碌 runner 上輪詢次數不夠）。
        switchSidebarTab(
            app: app, tabLabel: "內容與安全",
            expectedRow: app.buttons[QAAccessibilityID.settingsStorageRow], rowDescription: "儲存空間"
        )

        assertPushThenBackReturnsToList(
            app: app,
            entry: app.buttons[QAAccessibilityID.settingsStorageRow],
            pushedSentinel: app.staticTexts["照片與影片會佔用空間，日記文字不會。"]
        )
    }

    /// reviewer 原始複現三支之一：「切到『帳號』→ 點『刪除帳號』→ 沒有 push」。
    /// LS-193：`DeleteAccountFlowView` 從 LS-188 的最小佔位（`ContentUnavailableView`「刪除帳號
    /// 流程尚未推出，敬請期待。」）換成正式內容——`pushedSentinel` 改認 04a 一般成員的說明副標
    /// （merge-review R1 M1 訂正後：`.settingsRegular` harness 改用
    /// `TapTargetGateHarness.settingsFamilyStore(withFamily:)` 同步 seed `ownerUserID`／
    /// `members`（自己是 `.member`、另一位是 `.owner`），`classifyDeleteAccountFlow` 因此
    /// 確定性地落在 `.generalMember`、進 04a，不會是 04b／04d——不再依賴 R1 版
    /// `FamilyStore.leaveFlowCase` 對「`ownerUserID` 是 nil」的處置）。
    func testAccountSectionDeleteRowPushesAndBackReturns() {
        let app = TapTargetMeasurement.launch(.settingsRegular)
        TapTargetMeasurement.assertScreenRendered(.settingsRegular, in: app)

        // LS-253 R2（merge-review R1 m1）：與家庭／內容與安全／法律同類，「帳號」sidebar 切換
        // tap 也補上 waitForHittable 同步點——同一種轉場競速風險，同檔其餘四處都已補過。
        // LS-261（LS-96 池 `a3778131`）：09-13 ci-ipad 同類紅第 5 次，紅在「切到「帳號」後應該
        // 看得到「刪除帳號」列」這一步——與 LS-245 內容與安全那次同一種失敗（忙碌 runner 上單次
        // snapshot 偏慢，5s 只夠輪詢 1–2 次）。改走統一的 `switchSidebarTab` helper，timeout
        // 對齊 10s。
        switchSidebarTab(
            app: app, tabLabel: "帳號",
            expectedRow: app.buttons["刪除帳號"], rowDescription: "刪除帳號"
        )

        assertPushThenBackReturnsToList(
            app: app,
            entry: app.buttons["刪除帳號"],
            pushedSentinel: app.staticTexts["在你刪除帳號之前，請先看看接下來會發生什麼事。"]
        )
    }

    /// LS-210：「法律」兩列原本是 `Link`（開系統瀏覽器，不是 app 內 push，沒有返回鈕可驗，只驗證
    /// sidebar 切換與兩列存在）——改開 in-app `LegalDocumentSheet` 後，這裡改驗證「點列會開啟
    /// 對應的 sheet、關閉後回到列表」，iPad regular 佈局下 `.sheet()` 是置中 form sheet
    /// （`LegalDocumentSheet` 文件註解「iPad」段），與 iPhone compact 共用同一個
    /// `.sheet(item:)` 綁定（`SettingsView.body`），沒有另外的 iPad 專屬分支需要覆蓋。
    ///
    /// **不能只用 doc title staticText 存在／不存在判斷**（`SettingsViewTests` 實測踩到的同一個
    /// 坑，兩層問題，見該檔文件註解）：(1) `SettingsRowView` 的列 label 本身就是一字不差的
    /// 「使用條款」`Text`，且 SwiftUI `.sheet()` 呈現時底下畫面的 accessibility 元件並不會
    /// 被隱藏——關閉後列重新可見會讓同一個查詢誤判成「還沒關掉」，改用「關閉」鈕本身的存在與否
    /// （這顆鈕只在 sheet 裡出現）；(2) 同一個「底下的列全程留在 tree 裡」的事實也讓單純判斷
    /// 「Doc Title 存在」測不出「開錯文件」——改用數量比對（列＋Doc Title 各一個＝2；只剩列
    /// 本身＝1，代表開錯文件）。
    func testLegalSectionRowsOpenAndCloseLegalDocumentSheet() {
        let app = TapTargetMeasurement.launch(.settingsRegular)
        TapTargetMeasurement.assertScreenRendered(.settingsRegular, in: app)

        // LS-253（同上，家庭／法律兩處 sidebar 切換 tap 當時漏補，見上方訂正）：補上同一套
        // `waitForHittable` 同步點。
        // LS-261：改走統一的 `switchSidebarTab` helper，等待目標列出現的 timeout 由 5s 對齊 10s。
        // merge-review R1 m2：`switchSidebarTab` 只保證 `termsRow` 的 `exists`，tap 前還缺
        // 「真的可點」同步點——同一互動在 iPhone 版 `SettingsViewTests.swift`（LS-259 `2f88874`）
        // 已補過，iPad 版原本反而少一道，這裡補齊。
        let termsRow = app.buttons["使用條款"]
        switchSidebarTab(app: app, tabLabel: "法律", expectedRow: termsRow, rowDescription: "使用條款")
        XCTAssertTrue(waitForHittable(termsRow, timeout: 5), "「使用條款」列應該可點擊")
        termsRow.tap()

        let closeButton = app.buttons["關閉"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "點擊「使用條款」列應開啟 LegalDocumentSheet（Footer「關閉」鈕可見）")
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "使用條款")).count, 2,
            "應同時看到「使用條款」列與 Doc Title 兩個「使用條款」文字元件——只剩 1 個代表開錯文件"
        )
        // merge-review R1 m2：關閉鈕同樣補 tap 前的 hittable 同步點——sheet 開闔轉場尚未穩定時
        // tap 落空，下一行等「隱私權政策」列自然逾時，同型於 LS-253／LS-259 修過的失敗模式。
        XCTAssertTrue(waitForHittable(closeButton, timeout: 5), "「關閉」鈕應該可點擊")
        closeButton.tap()
        // LS-237 第 8 項（coordinator 追加，09-13 run 34707282145 flake）：`XCTAssertFalse
        // (closeButton.waitForExistence(timeout: 3), ...)` 用的是「等開始存在」的 API 驗證
        // 「不存在」——tap 後 dismiss 動畫還沒跑完的那個瞬間，第一次輪詢就可能量到「還存在」，
        // `waitForExistence` 因此立刻回傳 `true`（不會等滿 3 秒看它會不會消失），斷言就此
        // 誤判失敗。改用真正等「停止存在」的 `waitForNonExistence`。
        // LS-253 R2（merge-review R1 M1）：timeout 由 3s 拉到 10s——run 34741136505 attempt 1
        // 證實 sheet 其實有關掉（下一行馬上點到「隱私權政策」），純粹是忙碌 runner 上單次
        // accessibility snapshot 就吃掉 2.3s，3s 只夠輪詢 1–2 次；3s 也是全 repo
        // `waitForNonExistence` 呼叫裡唯一的離群值（本檔 L51 用 10、`ContentActionsUITests.swift`／
        // `DiaryDetailCommentsUITests.swift` 用 5），對齊本檔 L51 同類「轉場後等消失」情境。
        XCTAssertTrue(
            waitForNonExistence(closeButton, timeout: 10), "點擊關閉後 sheet 應消失（Footer「關閉」鈕不應再存在）"
        )

        // LS-261：關閉 sheet 後「回到列表」這一步與 `assertPushThenBackReturnsToList` 的 back
        // 相關等待同性質，timeout 由 5s 對齊 10s。
        let privacyRow = app.buttons["隱私權政策"]
        XCTAssertTrue(privacyRow.waitForExistence(timeout: 10), "關閉後應回到「法律」列表，看得到「隱私權政策」列")
        // merge-review R1 m2：與 termsRow／closeButton 同型，tap 前補 hittable 同步點。
        XCTAssertTrue(waitForHittable(privacyRow, timeout: 5), "「隱私權政策」列應該可點擊")
        privacyRow.tap()
        XCTAssertTrue(app.buttons["關閉"].waitForExistence(timeout: 5), "點擊「隱私權政策」列應開啟 LegalDocumentSheet（Footer「關閉」鈕可見）")
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "隱私權政策")).count, 2,
            "應同時看到「隱私權政策」列與 Doc Title 兩個「隱私權政策」文字元件——只剩 1 個代表開錯文件（不是誤開使用條款）"
        )
    }

    /// merge-review R3 M3（major）：R3 版本用 `XCUIElement.isSelected` 當訊號，reviewer 四組
    /// mutation 證明這個讀值跟驅動視覺的 `isSelected` 變數完全無關（拿掉 trait 那行測到的其實
    /// 是 app crash，不是斷言鑑別力；trait 全拿掉／全部套用／視覺修法整個中性化，`isSelected`
    /// 讀值都不受影響，測試依然全綠）——`.isSelected` 在這個 SwiftUI ForEach+Button 組合下不
    /// 忠實反映 `.accessibilityAddTraits(.isSelected)`。
    ///
    /// R4 修法：選中態改用 `.accessibilityValue("已選取")`（`SettingsView+Sidebar.sidebarRow`）
    /// ——這是獨立於 trait 的另一個 accessibility 通道，`XCUIElement.value` 忠實反映它。這裡改
    /// 斷言「五列裡恰好一列的 value 是『已選取』，且切換 sidebar 後這個訊號跟著移動」，不再依賴
    /// `.isSelected`。純視覺樣式（邊框／陰影／背景色／字重）本身另由 `SettingsSidebarRowStyleTests`
    /// 這個純函式單元測試釘住（見該檔文件註解）——這條 UITest 對「視覺修法被中性化但 value 標記
    /// 還在」這種 mutation 不會轉紅是預期行為，責任分工在單元測試層。
    func testSidebarSelectionIsAccessibleAndDistinguishable() {
        let app = TapTargetMeasurement.launch(.settingsRegular)
        TapTargetMeasurement.assertScreenRendered(.settingsRegular, in: app)

        let labels = ["個人", "家庭", "內容與安全", "法律", "帳號"]
        func selectedLabels() -> [String] {
            labels.filter { (app.buttons[$0].value as? String) == "已選取" }
        }

        XCTAssertEqual(selectedLabels(), ["個人"], "預設應該恰好一列帶「已選取」訊號，且是「個人」")

        // LS-253 R2（merge-review R1 m1）：這裡 tap 後直接同步讀 `selectedLabels()`，本檔最脆的
        // 一行——tap 前補 `waitForHittable` 同步點。
        //
        // LS-259 第 4 項（merge-review R2 informational i4，`0bb126d4`）：訂正下一行
        // `waitForExistence` 的因果陳述——「家庭」列 tap 前已確認 hittable、選取後也不會離開
        // accessibility tree，所以這個 `exists` 判斷本身近乎恆真，並不是像原註解說的「先確認
        // 列仍在 tree 裡才讀值、避免轉場瞬間讀到過渡態」那個機制（無法偵測、也無法等待 value
        // 轉換）。它真正的效益是 `XCTNSPredicateExpectation` 附帶的輪詢延遲，讓「已選取」訊號
        // 的轉場多一點時間沉澱再讀值。**不要改成直接等 `value == "已選取"`**——那會讓下一行的
        // `XCTAssertEqual` 斷言恆真（等到成立才斷言成立）。保留這個寫法（等一個正交屬性）是
        // 刻意的取捨，不是疏漏。
        let familyTab = app.buttons["家庭"]
        XCTAssertTrue(waitForHittable(familyTab, timeout: 5), "「家庭」sidebar 列應該可點擊")
        familyTab.tap()
        XCTAssertTrue(familyTab.waitForExistence(timeout: 5), "借輪詢延遲讓「已選取」轉場沉澱，才讀取 accessibility value")
        XCTAssertEqual(selectedLabels(), ["家庭"], "點擊「家庭」後「已選取」訊號應該恰好移到「家庭」，其餘四列都不再帶")
    }
}

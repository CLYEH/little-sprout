import XCTest

/// LS-158：`QASmokeTests` 三個情境共用的 app 驅動步驟——啟動（注入本機容器的 URL／anon key）、
/// 每步截圖、等元素（等不到就附 a11y 階層＋截圖再 `XCTFail`）、登入／建家庭／編輯器／相簿選圖
/// ／瀏覽。按鈕沿用可見 label（同 `SectionTabBarPushRegressionTests` 慣例），輸入欄與卡片用
/// `QAAccessibilityID`（文案會隨對稿改，identifier 不會）。
@MainActor
final class QADriver {
    let app = XCUIApplication()
    let env: QAEnvironment
    private let testCase: XCTestCase
    private var stepIndex = 0

    init(env: QAEnvironment, testCase: XCTestCase) {
        self.env = env
        self.testCase = testCase
    }

    static func stamp() -> String {
        String(Int(Date().timeIntervalSince1970))
    }

    // MARK: - 啟動／截圖／等待

    /// `SupabaseClientFactory.qaOverride`（DEBUG）讀這三個 launch environment 把 app 指向本機容器。
    func launch() {
        app.launchEnvironment["LS_QA_API_URL"] = env.apiURL
        app.launchEnvironment["LS_QA_ANON_KEY"] = env.anonKey
        app.launchEnvironment["LS_QA_SCENARIO"] = env.scenario.rawValue
        app.launch()
    }

    /// 每步一張，名稱 `<情境>-<序號>-<步驟>`；`qa-e2e.sh` 依 xcresult manifest 的
    /// `suggestedHumanReadableName` 把匯出的 PNG 改回這個名字。
    func snap(_ name: String) {
        stepIndex += 1
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = String(format: "%@-%02d-%@", env.scenario.rawValue, stepIndex, name)
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    func attachHierarchy(reason: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "\(env.scenario.rawValue)-hierarchy-\(reason)"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    /// 等元素出現；等不到＝這一步失敗：附 a11y 階層（看得出停在哪個畫面）＋截圖，`XCTFail` 後丟錯。
    @discardableResult
    func require(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15) throws -> XCUIElement {
        guard element.waitForExistence(timeout: timeout) else {
            attachHierarchy(reason: what)
            snap("fail")
            XCTFail("步驟 \(stepIndex)：\(Int(timeout)) 秒內沒等到「\(what)」——a11y 階層與截圖已附在 xcresult")
            throw QAFailure.screen(what)
        }
        return element
    }

    /// 幾個候選元素任一出現就回它的名字；全部沒出現回 nil（呼叫端決定怎麼失敗）。
    func waitForAny(_ candidates: [(element: XCUIElement, name: String)], timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for candidate in candidates where candidate.element.exists { return candidate.name }
            _ = candidates[0].element.waitForExistence(timeout: 0.5)
        } while Date() < deadline
        return nil
    }

    // MARK: - 畫面元素

    var welcomeEmailButton: XCUIElement { app.buttons["使用 Email 登入"] }
    /// `TimelineView.headerRow` 自畫的標題（系統 nav bar 在時間軸被隱藏），同 `SectionTabBarTests` 用法。
    var timelineHeading: XCUIElement { app.staticTexts["時間軸"].firstMatch }
    var forkCreateFamilyRow: XCUIElement { app.buttons["我要自己建立家庭"] }
    var forkGreeting: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "歡迎，")).firstMatch
    }
    var diaryCards: XCUIElementQuery { app.buttons.matching(identifier: QAAccessibilityID.timelineDiaryCard) }

    // MARK: - 登入

    func signInWithEmailOTP() async throws {
        try require(welcomeEmailButton, "歡迎頁「使用 Email 登入」").tap()
        let emailField = try require(app.textFields[QAAccessibilityID.emailField], "Email 欄位")
        emailField.tap()
        emailField.typeText(env.email)
        snap("email-entered")
        let sentAt = Date()
        try require(app.buttons["寄送驗證碼"], "寄送驗證碼").tap()
        try require(app.staticTexts["輸入驗證碼"], "驗證碼畫面（OTP 已寄出）", timeout: 20)
        snap("otp-screen")
        let code = try await fetchOTP(sentAfter: sentAt)
        // `OTPCodeField` 整列是單一 a11y element，點它叫出數字鍵盤後 `typeText` 進隱形 TextField。
        try require(app.otherElements[QAAccessibilityID.otpCodeField], "六格驗證碼欄").tap()
        app.typeText(code)
        snap("otp-entered")
        try require(app.buttons["確認登入"], "確認登入").tap()
    }

    private func fetchOTP(sentAfter: Date) async throws -> String {
        do {
            return try await QAMailpit.fetchOTP(mailpit: env.mailpitURL, email: env.email, sentAfter: sentAfter)
        } catch {
            snap("fail-otp-mail")
            XCTFail("Mailpit 取碼失敗：\(error)（Mailpit \(env.mailpitURL)、收件人 \(env.email)）")
            throw error
        }
    }

    /// 登入後的落點：有家庭→時間軸；沒家庭→三岔路（`ForkView`「歡迎，…」）。兩個都不是＝失敗。
    func assertLandedAfterLogin() throws {
        let landed = waitForAny([(timelineHeading, "時間軸"), (forkGreeting, "三岔路")], timeout: 30)
        guard let landed else {
            attachHierarchy(reason: "login-landing")
            snap("fail-landing")
            XCTFail("登入後 30 秒內既沒到時間軸也沒到三岔路（session 沒建立、或家庭查詢卡住）")
            throw QAFailure.screen("登入落點")
        }
        snap(landed == "時間軸" ? "landed-timeline" : "landed-fork")
    }

    /// 模擬器 Keychain 還留著 session（上一個情境登入過）就直接沿用，否則走一次 OTP 登入。
    func ensureLoggedIn() async throws {
        launch()
        if welcomeEmailButton.waitForExistence(timeout: 8) {
            snap("welcome")
            try await signInWithEmailOTP()
        }
        try assertLandedAfterLogin()
    }

    // MARK: - 家庭

    /// 三岔路→「我要自己建立家庭」→建立→寶貝建檔（`fullScreenCover`）按「之後再說」→時間軸。
    func ensureFamily() throws {
        if forkCreateFamilyRow.waitForExistence(timeout: 3) {
            forkCreateFamilyRow.tap()
            let nameField = try require(app.textFields[QAAccessibilityID.familyNameField], "家庭名稱欄")
            nameField.tap()
            nameField.typeText("QA e2e")
            snap("create-family")
            try require(app.buttons["建立家庭"], "建立家庭").tap()
            try require(app.buttons["之後再說"], "寶貝建檔頁（可跳過）", timeout: 30).tap()
        }
        try require(timelineHeading, "時間軸", timeout: 30)
        snap("timeline")
    }

    // MARK: - 日記編輯器

    func openEditor() throws {
        try require(app.buttons["新增回憶"], "時間軸「新增回憶」").tap()
        try require(app.staticTexts["寫日記"], "日記編輯器")
    }

    func typeDiaryBody(_ text: String) throws {
        let editor = try require(app.textViews[QAAccessibilityID.diaryBodyEditor], "日記內文欄")
        editor.tap()
        editor.typeText(text)
        snap("body-typed")
    }

    /// 發佈→編輯器 pop 回時間軸→`.task(id:)` 重跑 refresh→剛發的卡出現（含上傳，給 90 秒）。
    func publishAndWaitForCard(body: String) throws {
        try require(app.buttons["發佈日記"], "發佈日記").tap()
        let card = diaryCards.matching(NSPredicate(format: "label CONTAINS %@", body)).firstMatch
        try require(card, "時間軸上剛發佈的日記卡「\(body)」", timeout: 90)
        snap("published-card")
    }

    // MARK: - 相簿選圖（PhotosPicker）

    /// `PhotosPicker` 是另一個行程的系統 UI，但它的元素仍掛在被測 app 的 a11y tree 下。cell label
    /// 依**模擬器系統語言**（不是 app 語言）：英文 `Photo, …`／`Video, …`，中文 `照片`／`影片`；
    /// 取**最後一個**符合的 cell＝最新加入的 fixture（`qa-e2e.sh` 跑前 `simctl addmedia`）。
    func attachFixturesFromPhotoLibrary() throws {
        try require(app.buttons["新增照片"], "「新增照片」").tap()
        try newestPickerCell(kinds: ["Photo", "照片", "相片"], what: "相簿選擇器裡的照片格").tap()
        try newestPickerCell(kinds: ["Video", "影片", "視訊"], what: "相簿選擇器裡的影片格").tap()
        snap("picker-selected")
        try require(pickerConfirmButton, "相簿選擇器的加入鈕（Add／加入）").tap()
        let queued = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "共 2 張")).firstMatch
        try require(queued, "照片佇列顯示 2 張（照片＋影片載入完成）", timeout: 60)
        snap("queue-2-items")
    }

    private func newestPickerCell(kinds: [String], what: String) throws -> XCUIElement {
        let clauses = kinds.map { _ in "label BEGINSWITH %@" }.joined(separator: " OR ")
        let query = app.descendants(matching: .any).matching(NSPredicate(format: clauses, argumentArray: kinds))
        try require(query.firstMatch, what, timeout: 20)
        return query.element(boundBy: max(0, query.count - 1))
    }

    private var pickerConfirmButton: XCUIElement {
        let predicate = NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label == %@ OR label == %@",
            "Add", "加入", "Done", "完成"
        )
        return app.buttons.matching(predicate).firstMatch
    }

    // MARK: - 瀏覽

    /// 時間軸沒有任何日記卡（空狀態）就先發一篇純文字日記當瀏覽對象——`browse` 不依賴先跑過 `publish`。
    func seedDiaryIfTimelineEmpty() throws {
        if diaryCards.firstMatch.waitForExistence(timeout: 10) { return }
        try openEditor()
        let body = "LS-158 browse seed \(Self.stamp())"
        try typeDiaryBody(body)
        try publishAndWaitForCard(body: body)
    }

    /// 日記卡→詳情（內文＋照片牆）→返回→相簿分頁→時間軸分頁。
    func browseDetailAndAlbums() throws {
        try require(diaryCards.firstMatch, "時間軸日記卡", timeout: 20).tap()
        try require(app.staticTexts[QAAccessibilityID.diaryDetailBody], "日記詳情內文", timeout: 20)
        // 照片牆是非同步簽名＋下載——有附照的日記等它畫出來再截（純文字日記本來就沒有，等 10 秒放行）。
        _ = app.images.firstMatch.waitForExistence(timeout: 10)
        snap("detail")
        app.navigationBars.buttons.firstMatch.tap()
        try require(timelineHeading, "返回時間軸", timeout: 15)
        try require(app.buttons["相簿"], "Tab Bar「相簿」").tap()
        try require(app.navigationBars["相簿"], "相簿頁", timeout: 15)
        snap("albums")
        try require(app.buttons["時間軸"], "Tab Bar「時間軸」").tap()
        try require(timelineHeading, "回到時間軸", timeout: 15)
        snap("timeline-again")
    }
}

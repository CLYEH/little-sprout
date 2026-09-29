import XCTest

/// LS-404（`design/littlesprout.pen` LS-402 板 `HOKKA`／`Ej5G5`／`JNDUz`）：設定頁最上方「正在新增照片」
/// 上傳佇列入口列（iPhone）。
///
/// 共用 `TapTargetGateHarness+UploadQueueEntry.swift` 的 `.settingsUploadQueueEntry`（真的 `SettingsView`＋種好狀態
/// 的佇列＋底部真的 `SectionTabBar`）。座標斷言一律相對參照（入口列對「個人」段標題、對 Tab Bar 本身），
/// 不用絕對常數——不同 runtime／機型的頁面偏移不同（LS-167 教訓）。
///
/// 停留期間行為（bqnO1，C1a）在真實版面實測：全部完成原地換態、失敗出現不增行——都以「下方內容 y 不動」
/// 斷言「頁面沒有被搬動」。iPad 版面見 `UploadQueueEntryIPadTests`。
@MainActor
final class UploadQueueEntryUITests: XCTestCase {
    private static let xSmall = "UICTContentSizeCategoryXS"
    private static let large = "UICTContentSizeCategoryL"
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    /// 各態的 VoiceOver 文案（乾淨版，見 `UploadQueueEntryCopy.accessibilityLabel`）。
    private static let inProgressLabel = "正在新增照片，還有 27 張還沒完成"
    private static let withFailureLabel = "正在新增照片，還有 27 張還沒完成，1 張沒有成功"
    /// `progressThenFailedOnly`：起始「還有 9 張」、劇本結束「還有 1 張」（位數不變，見 harness 註解）。
    private static let startLabel = "正在新增照片，還有 9 張還沒完成"
    private static let almostDoneLabel = "正在新增照片，還有 1 張還沒完成"
    private static let onlyFailedLabel = "有 1 張照片沒有加進去，看原因，或再試一次"

    override func setUpWithError() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad, "iPhone（compact）版面測試；iPad 見 UploadQueueEntryIPadTests"
        )
    }

    // MARK: - 淺深 × xSmall／預設／AX3：位置、文案、Tab Bar 不遮

    func testEntryRow_threeStaticStates_lightDark_xSmallDefaultAX3() throws {
        let expectations = [
            ("progress", Self.inProgressLabel), ("progressFailure", Self.withFailureLabel),
            ("onlyFailed", Self.onlyFailedLabel)
        ]
        for scheme in ["light", "dark"] {
            for size in [Self.xSmall, Self.large, Self.ax3] {
                for (fixture, label) in expectations {
                    let context = "\(fixture)/\(scheme)/\(size)"
                    let app = launch(fixture: fixture, size: size, scheme: scheme)
                    let row = entryRow(in: app)
                    XCTAssertEqual(row.label, label, "[\(context)] 入口列文案照稿逐字（乾淨版）")
                    assertPlacedAboveProfileSection(row, in: app, context: context)
                    assertNotCoveredByTabBar(row, in: app, context: context)
                    XCTAssertGreaterThanOrEqual(row.frame.height, 44, "[\(context)] 列高 ≥44pt")
                    print("LS-404 rowHeight \(context)=\(row.frame.height) width=\(row.frame.width)")
                    attach(app, name: "entry-\(fixture)-\(scheme)-\(size)")
                    app.terminate()
                }
            }
        }
    }

    /// AX3（稿面 `JNDUz`）：進行中／只剩失敗各 4 行，含失敗行 6 行——第三行讓列高明顯更高，且都不超出
    /// 稿面列高（257／379）太多（沒有失控換行）。
    func testEntryRow_ax3_rowHeightsFollowDesignLineCounts() {
        var heights: [String: CGFloat] = [:]
        for fixture in ["progress", "progressFailure", "onlyFailed"] {
            let app = launch(fixture: fixture, size: Self.ax3, scheme: "light")
            heights[fixture] = entryRow(in: app).frame.height
            app.terminate()
        }
        let progress = heights["progress"] ?? 0
        let withFailure = heights["progressFailure"] ?? 0
        let onlyFailed = heights["onlyFailed"] ?? 0
        XCTAssertGreaterThan(withFailure, progress + 40, "AX3 含失敗行（6 行）應明顯高於 4 行態，量到 \(withFailure) vs \(progress)")
        XCTAssertLessThanOrEqual(progress, 257 * 1.25, "AX3 進行中（稿面 4 行 257）量到 \(progress)，不應失控換行")
        XCTAssertLessThanOrEqual(onlyFailed, 257 * 1.25, "AX3 只剩失敗（稿面 4 行 257）量到 \(onlyFailed)")
        XCTAssertLessThanOrEqual(withFailure, 379 * 1.25, "AX3 含失敗行（稿面 6 行 379）量到 \(withFailure)")
    }

    // MARK: - 沒有未完成項：列與 Card 都不存在，也不多佔間距

    func testNoUnfinishedItems_rowAbsent_andNoExtraGapAboveProfileSection() {
        let app = launch(fixture: "none", size: Self.large, scheme: "light")
        XCTAssertFalse(
            app.buttons[QAAccessibilityID.settingsUploadQueueRow].waitForExistence(timeout: 2),
            "全部完成、沒有任何未完成項：不顯示入口列"
        )
        let subtitle = app.staticTexts["「測試家庭」的帳號與家庭設定都在這裡。"]
        let profileHeader = app.staticTexts["個人"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 5) && profileHeader.exists)
        // 稿面 Content 上緣 `$sp-section`＝44：入口列隱藏時「個人」段標題離副標仍是 44，不因空的入口位置多出 24。
        XCTAssertEqual(profileHeader.frame.minY - subtitle.frame.maxY, 44, accuracy: 4, "入口列隱藏時不應多佔 VStack 間距")
    }

    // MARK: - 點擊：開佇列 sheet（四態同一個入口），關閉後列仍在

    func testTappingRow_opensQueueSheet_thenClosingKeepsRow() {
        let app = launch(fixture: "progressFailure", size: Self.large, scheme: "light")
        let row = entryRow(in: app)
        XCTAssertTrue(row.waitForHittable(timeout: 10))
        row.tap()
        let footer = app.buttons["在背景繼續，關閉視窗"]
        XCTAssertTrue(footer.waitForExistence(timeout: 10), "點入口列應 present 上傳佇列 sheet（Footer「在背景繼續，關閉視窗」可見）")
        XCTAssertTrue(footer.waitForHittable(timeout: 10))
        footer.tap()
        XCTAssertTrue(footer.waitUntilGone(timeout: 10), "關閉 sheet")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "sheet 關閉後入口列仍在（失敗項還在）")
        XCTAssertTrue(row.label.contains("1 張沒有成功"), "sheet 關閉是情境邊界，重新評估後仍是含失敗的態，實際：\(row.label)")
    }

    // MARK: - 停留期間（bqnO1）

    /// 進行中→全部完成：兩行態列高相同，原地換成「照片都加好了」，頁面其餘內容 y 不動。
    func testStay_progressToAllDone_switchesInPlace_pageDoesNotMove() {
        let app = launch(fixture: "allDone", size: Self.large, scheme: "light")
        let row = entryRow(in: app)
        XCTAssertEqual(row.label, Self.inProgressLabel)
        let headerY = app.staticTexts["個人"].frame.minY
        let rowFrame = row.frame
        XCTAssertTrue(
            waitForLabel(row, "照片都加好了，30 張都加進相簿了", timeout: 10),
            "停留期間全部完成：原地換成「照片都加好了」，實際 label：\(row.label)"
        )
        XCTAssertEqual(app.staticTexts["個人"].frame.minY, headerY, accuracy: 0.5, "原地換態：「個人」段沒有被搬動")
        XCTAssertEqual(row.frame.height, rowFrame.height, accuracy: 0.5, "列高不變")
        XCTAssertEqual(row.frame.minY, rowFrame.minY, accuracy: 0.5)
        attach(app, name: "entry-allDone-stay")
    }

    /// 進行中期間一張失敗、另一張完成：只更新數字，不增行（不出現第三行）、頁面不動。
    func testStay_failureAppearsMidStay_onlyNumbersUpdate_noExtraLine() {
        let app = launch(fixture: "stayFailure", size: Self.large, scheme: "light")
        let row = entryRow(in: app)
        XCTAssertEqual(row.label, Self.inProgressLabel)
        let headerY = app.staticTexts["個人"].frame.minY
        let height = row.frame.height
        XCTAssertTrue(
            waitForLabel(row, "正在新增照片，還有 26 張還沒完成", timeout: 10),
            "數字照常更新（失敗仍算在「還沒完成」，之後一張完成 27→26），實際 label：\(row.label)"
        )
        XCTAssertFalse(row.label.contains("沒有成功"), "停留期間不增行：第三行「M 張沒有成功」要等情境邊界")
        XCTAssertEqual(row.frame.height, height, accuracy: 0.5, "列高不變＝沒有增行")
        XCTAssertEqual(app.staticTexts["個人"].frame.minY, headerY, accuracy: 0.5, "頁面沒有被搬動")
        attach(app, name: "entry-stayFailure")
    }

    /// 進行中→只剩失敗（最後一張失敗）：列高相同才原地換態，否則維持原態等邊界——不論哪一種，
    /// 頁面都不能在停留期間被搬動（C1a）。
    func testStay_progressToOnlyFailed_neverMovesPageMidStay() {
        for size in [Self.xSmall, Self.large, Self.ax3] {
            let app = launch(fixture: "progressThenFailedOnly", size: size, scheme: "light")
            let row = entryRow(in: app)
            XCTAssertEqual(row.label, Self.startLabel)
            let headerY = app.staticTexts["個人"].frame.minY
            let height = row.frame.height
            Thread.sleep(forTimeInterval: 7) // 劇本 4 秒後把佇列改成只剩 1 張失敗
            XCTAssertEqual(app.staticTexts["個人"].frame.minY, headerY, accuracy: 0.5, "[\(size)] 停留期間頁面不能被搬動")
            XCTAssertEqual(row.frame.height, height, accuracy: 0.5, "[\(size)] 停留期間列高不能改變")
            print("LS-404 progressToOnlyFailed \(size) label=\(row.label)")
            XCTAssertTrue(
                row.label == Self.almostDoneLabel
                    || row.label == Self.onlyFailedLabel,
                "[\(size)] 只能是原態（數字更新）或原地換成只剩失敗，實際：\(row.label)"
            )
            app.terminate()
        }
    }

    // MARK: - helpers

    private func launch(fixture: String, size: String, scheme: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = TapTargetGateScreenName.settingsUploadQueueEntry.rawValue
        app.launchEnvironment["LS_UPLOAD_QUEUE_ENTRY_FIXTURE"] = fixture
        app.launchEnvironment["LS_UPLOAD_QUEUE_ENTRY_SCHEME"] = scheme
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        app.launch()
        return app
    }

    private func entryRow(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let row = app.buttons[QAAccessibilityID.settingsUploadQueueRow]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "設定頁最上方應出現上傳佇列入口列", file: file, line: line)
        return row
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// 入口列在 Content 第一段：在「個人」段標題之上（相對參照），且落在 Header Row 副標之下。
    private func assertPlacedAboveProfileSection(_ row: XCUIElement, in app: XCUIApplication, context: String) {
        let profileHeader = app.staticTexts["個人"]
        XCTAssertTrue(profileHeader.exists, "[\(context)] 個人段標題應存在")
        XCTAssertLessThan(row.frame.maxY, profileHeader.frame.minY, "[\(context)] 入口列應在「個人」段之上")
        XCTAssertGreaterThan(row.frame.minY, app.staticTexts["設定"].frame.maxY, "[\(context)] 入口列應在 Header Row 之下")
    }

    /// 入口列完整落在 Tab Bar 之上（不被浮動的 Tab Bar 遮住）。
    private func assertNotCoveredByTabBar(_ row: XCUIElement, in app: XCUIApplication, context: String) {
        let tabBar = app.buttons["設定"] // Tab Bar 的「設定」cell（label 即分頁名）
        XCTAssertTrue(tabBar.exists, "[\(context)] Tab Bar 應存在")
        XCTAssertLessThanOrEqual(row.frame.maxY, tabBar.frame.minY, "[\(context)] 入口列不應被 Tab Bar 遮住")
        XCTAssertTrue(row.isHittable, "[\(context)] 入口列應可點")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

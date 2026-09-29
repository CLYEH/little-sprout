import XCTest

/// LS-404（`design/littlesprout.pen` LS-402 板 `Hzv2U`）：iPad 側欄——入口列在 Sidebar 標題「設定」之下、
/// Nav List 之上；側欄窄，Label 較早換行，「進行中→只剩失敗」列高會不同（稿面 100→125），停留期間不得
/// 原地換態把 Nav List 往下推（C1a）。
///
/// 類別名以 `IPadTests` 結尾：CI `ci-ipad` 與 push-gate 的 iPad best-effort 用 `list-ipad-tests.sh` 依名稱選測試；
/// iPhone 專屬機上 `XCTSkipUnless(pad)` 略過（同 `SettingsViewIPadTests` 慣例）。座標斷言一律相對參照。
@MainActor
final class UploadQueueEntryIPadTests: XCTestCase {
    private static let large = "UICTContentSizeCategoryL"
    private static let inProgressLabel = "正在新增照片，還有 27 張還沒完成"
    /// `progressThenFailedOnly`：起始「還有 9 張」、劇本結束「還有 1 張」（位數不變，見 harness 註解）。
    private static let startLabel = "正在新增照片，還有 9 張還沒完成"
    private static let almostDoneLabel = "正在新增照片，還有 1 張還沒完成"
    private static let onlyFailedLabel = "有 1 張照片沒有加進去，看原因，或再試一次"

    override func setUpWithError() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad 專屬版面測試，非 iPad 裝置（例如 push-gate 常態用的 iPhone 專屬機）略過"
        )
    }

    func testEntryRow_sitsBetweenSidebarTitleAndNavList() {
        let app = launch(fixture: "progress", scheme: "light")
        let row = app.buttons[QAAccessibilityID.settingsUploadQueueRow]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "iPad 側欄應出現上傳佇列入口列")
        XCTAssertEqual(row.label, Self.inProgressLabel)
        let title = app.staticTexts["設定"].firstMatch
        let firstNavItem = app.buttons["個人"].firstMatch
        XCTAssertTrue(title.exists && firstNavItem.exists)
        XCTAssertGreaterThan(row.frame.minY, title.frame.maxY, "入口列應在側欄標題「設定」之下")
        XCTAssertLessThan(row.frame.maxY, firstNavItem.frame.minY, "入口列應在 Nav List 之上")
        XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        print("LS-404 iPad rowHeight progress=\(row.frame.height) width=\(row.frame.width)")
        attach(app, name: "entry-ipad-progress")
    }

    func testEntryRow_darkMode_rendersSameState() {
        let app = launch(fixture: "progressFailure", scheme: "dark")
        let row = app.buttons[QAAccessibilityID.settingsUploadQueueRow]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(row.label, Self.inProgressLabel + "，1 張沒有成功")
        attach(app, name: "entry-ipad-progressFailure-dark")
    }

    /// 停留期間佇列變成「只剩失敗」：不論列高是否相同，Nav List 不能被搬動；列高不同（稿面 100→125）時列必須
    /// 維持原態，列高相同時才可原地換態。跑多個中間字級（Label 較早換行，列高更可能不同），print 出各級實際走了
    /// 哪一支（原態／原地換態）供 handoff 引用。
    func testStay_progressToOnlyFailed_neverMovesNavListMidStay() {
        let sizes = ["UICTContentSizeCategoryL", "UICTContentSizeCategoryXXL", "UICTContentSizeCategoryAccessibilityM"]
        for size in sizes {
            let app = launch(fixture: "progressThenFailedOnly", scheme: "light", size: size)
            let row = app.buttons[QAAccessibilityID.settingsUploadQueueRow]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            XCTAssertEqual(row.label, Self.startLabel)
            let navItem = app.buttons["個人"].firstMatch
            let navY = navItem.frame.minY
            let height = row.frame.height
            Thread.sleep(forTimeInterval: 7)
            XCTAssertEqual(navItem.frame.minY, navY, accuracy: 0.5, "[\(size)] 停留期間 Nav List 不能被搬動")
            XCTAssertEqual(row.frame.height, height, accuracy: 0.5, "[\(size)] 停留期間列高不能改變")
            print("LS-404 iPad progressToOnlyFailed \(size) height=\(height) label=\(row.label)")
            XCTAssertTrue(
                row.label == Self.almostDoneLabel
                    || row.label == Self.onlyFailedLabel,
                "[\(size)] 只能是原態（數字更新）或原地換成只剩失敗，實際：\(row.label)"
            )
            attach(app, name: "entry-ipad-stay-\(size)")
            app.terminate()
        }
    }

    // MARK: - helpers

    private func launch(fixture: String, scheme: String, size: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = TapTargetGateScreenName.settingsUploadQueueEntry.rawValue
        app.launchEnvironment["LS_UPLOAD_QUEUE_ENTRY_FIXTURE"] = fixture
        app.launchEnvironment["LS_UPLOAD_QUEUE_ENTRY_SCHEME"] = scheme
        app.launchEnvironment["LS_UPLOAD_QUEUE_ENTRY_LAYOUT"] = "regular"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

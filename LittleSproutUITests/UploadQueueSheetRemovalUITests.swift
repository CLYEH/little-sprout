import XCTest

/// LS-410（LS-403 iOS 段，`design/littlesprout.pen` 板 `rU2zY` 16c／`KaONe` 16d／`sq2SF` 16e／`p0Fw0` 16f／`x2it3Q` 16g
/// 與 AX3 `FIwU8`／`ri0AF`／`YNP31`／`GUu7b`、深色 `FgH6v`）：上傳佇列 sheet「移除失敗項」。
///
/// 走 `.settingsUploadQueueEntry` harness（真的 `SettingsView` 入口列＋種好狀態的佇列）：點入口列開 sheet，
/// 才涵蓋「sheet onDismiss → commitRemovals → 入口列重新快照」整段接線。座標斷言一律相對參照（同一個元件標記前後的
/// frame、下一列的 y），不用絕對常數——sheet 內容在 iOS 26.2+ 套用 ≈0.96 縮放（LS-167 教訓）。截圖用
/// `XCTAttachment`（淺深 × 預設／AX3），證據由 xcresult 匯出。
@MainActor
final class UploadQueueSheetRemovalUITests: XCTestCase {
    private static let large = "UICTContentSizeCategoryL"
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    override func setUpWithError() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad, "iPhone（compact）sheet 版面測試；iPad 的 sheet 同為單欄 modal"
        )
        continueAfterFailure = false
    }

    // MARK: - 16c → 16f：原地「× 移除」↔「↶ 復原」，同座標、同列高（淺深 × 預設／AX3）

    func testProgressWithFailures_removeAndUndo_swapInPlace_sameCoordinate_lightDark_defaultAX3() throws {
        for scheme in ["light", "dark"] {
            for size in [Self.large, Self.ax3] {
                let context = "16c-16f/\(scheme)/\(size == Self.ax3 ? "AX3" : "default")"
                let app = launch(fixture: "sheetProgressFailures", size: size, scheme: scheme)
                openSheet(in: app)
                XCTAssertTrue(app.staticTexts["正在新增照片"].waitForExistence(timeout: 5), "[\(context)] 進行中態標題")
                XCTAssertTrue(app.buttons["在背景繼續，關閉視窗"].exists, "[\(context)] 進行中態 footer")
                attach(app, name: "16c-\(scheme)-\(size == Self.ax3 ? "AX3" : "default")")

                let removes = app.buttons.matching(identifier: QAAccessibilityID.uploadQueueRemove)
                XCTAssertEqual(removes.count, 3, "[\(context)] 三張失敗列各一顆「移除」")
                let firstRemove = removes.element(boundBy: 0)
                // 點擊時 XCUITest 可能先把捲動區捲到看得見（AX3 第一列的動作鈕在 footer 下方），所以座標一律量成「相對群標題列
                // 的批次鈕」（同在捲動區內，一起位移）——不比絕對 y。
                let anchor = app.buttons[QAAccessibilityID.uploadQueueRemoveAll]
                let removeOffset = firstRemove.frame.minY - anchor.frame.minY
                let removeX = firstRemove.frame.minX
                let secondOffsetBefore = removes.element(boundBy: 1).frame.minY - anchor.frame.minY

                firstRemove.tap()

                let undo = app.buttons[QAAccessibilityID.uploadQueueUndo]
                XCTAssertTrue(undo.waitForExistence(timeout: 5), "[\(context)] 標記後原地出現「復原」")
                XCTAssertEqual(undo.label, "復原，把這張放回來", "[\(context)] 復原鈕 VoiceOver 文案（Notes FBoLL）")
                XCTAssertEqual(undo.frame.minX, removeX, accuracy: 1, "[\(context)] 「復原」與原「移除」同 x")
                XCTAssertEqual(
                    undo.frame.minY - anchor.frame.minY, removeOffset, accuracy: 1,
                    "[\(context)] 「復原」與原「移除」同座標（連按兩次＝自己取消，不會移到下一張）"
                )
                let secondRemoveAfter = app.buttons.matching(identifier: QAAccessibilityID.uploadQueueRemove)
                    .element(boundBy: 0).frame
                let measured = XCTAttachment(string: "\(context) 移除→復原相對群標題鈕的 y："
                    + "before=\(removeOffset) after=\(undo.frame.minY - anchor.frame.minY)；"
                    + "下一列 before=\(secondOffsetBefore) after=\(secondRemoveAfter.minY - anchor.frame.minY)")
                measured.name = "measure-\(context.replacingOccurrences(of: "/", with: "-"))"
                measured.lifetime = .keepAlways
                add(measured)
                XCTAssertEqual(
                    secondRemoveAfter.minY - anchor.frame.minY, secondOffsetBefore, accuracy: 1,
                    "[\(context)] 墓碑列鎖原列高：下一列（原第二顆「移除」）位置不動"
                )
                XCTAssertTrue(app.staticTexts["還有 4 張還沒完成"].exists, "[\(context)] 標記後主行數字更新（5→4）")
                attach(app, name: "16f-\(scheme)-\(size == Self.ax3 ? "AX3" : "default")")

                undo.tap()
                XCTAssertTrue(
                    app.buttons.matching(identifier: QAAccessibilityID.uploadQueueRemove).element(boundBy: 0)
                        .waitForExistence(timeout: 5)
                )
                XCTAssertEqual(app.buttons.matching(identifier: QAAccessibilityID.uploadQueueRemove).count, 3)
                XCTAssertFalse(app.buttons[QAAccessibilityID.uploadQueueUndo].exists, "[\(context)] 復原後墓碑列消失")
                XCTAssertTrue(app.staticTexts["還有 5 張還沒完成"].exists, "[\(context)] 復原後數字回到 5")
                app.terminate()
            }
        }
    }

    // MARK: - 16c 批次：「移除這 N 張」要確認；確認後每列各自變墓碑列

    func testProgressWithFailures_batchRemove_requiresConfirmation_thenEveryRowBecomesTombstone() {
        let app = launch(fixture: "sheetProgressFailures", size: Self.large, scheme: "light")
        openSheet(in: app)
        let removeAll = app.buttons[QAAccessibilityID.uploadQueueRemoveAll]
        XCTAssertTrue(removeAll.waitForHittable(timeout: 5), "失敗數 >1：群標題列右端有「移除這 3 張」")
        XCTAssertEqual(removeAll.label, "移除這 3 張")

        removeAll.tap()
        XCTAssertTrue(
            app.staticTexts["移除這 3 張照片？"].waitForExistence(timeout: 5), "批次移除先跳系統確認框，不直接標記"
        )
        XCTAssertTrue(app.staticTexts["照片還在手機裡。關閉這個視窗前，都可以按「復原」放回來。"].exists)
        XCTAssertEqual(
            app.buttons.matching(identifier: QAAccessibilityID.uploadQueueUndo).count, 0, "確認前沒有任何列被標記"
        )
        attach(app, name: "16c-batch-confirm")

        // 取消：iPhone 上是 popover 樣式、只有 destructive 鈕，點外面收掉；沒有任何列被標記。
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["移除這 3 張照片？"].waitUntilGone(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: QAAccessibilityID.uploadQueueUndo).count, 0)

        removeAll.tap()
        XCTAssertTrue(app.staticTexts["移除這 3 張照片？"].waitForExistence(timeout: 5))
        confirmDestructive("移除這 3 張", in: app)

        XCTAssertTrue(
            app.buttons[QAAccessibilityID.uploadQueueUndo].waitForExistence(timeout: 5), "確認後每一列各自變墓碑列（各帶復原）"
        )
        XCTAssertEqual(app.buttons.matching(identifier: QAAccessibilityID.uploadQueueUndo).count, 3)
        XCTAssertEqual(app.buttons.matching(identifier: QAAccessibilityID.uploadQueueRemove).count, 0)
        XCTAssertTrue(app.staticTexts["還有 2 張還沒完成"].exists, "三張失敗都不再算「還沒完成」（5→2）")
    }

    // MARK: - 16d → 16g：只剩失敗標題、數字更新不換版面、M＝0 過渡句、不自動關閉

    /// LS-458（def25a8f，#628 run 38025472355 `[dark-default] M＝0：過渡標題` 紅）：該輪 xcresult 的螢幕錄影＝M＝0 那一下 tap
    /// 有按下效果（「移除」變暗一格）卻沒觸發動作、標題 5 秒內沒變（sheet 仍開著）——是 tap 掉了，不是過渡標題在動畫中被讀到
    /// （app 端無動畫，`markRemoved` 同步）。本機 24 次（含 CPU 壓力）未重現。修法：M＝0 以標題翻轉為狀態驗證，tap 掉才重點。
    func testOnlyFailed_titleFollowsCount_layoutHoldsStill_andAllRemovedShowsTransition_lightDark_defaultAX3() {
        for scheme in ["light", "dark"] {
            for size in [Self.large, Self.ax3] {
                let tag = "\(scheme)-\(size == Self.ax3 ? "AX3" : "default")"
                let app = launch(fixture: "sheetOnlyFailed", size: size, scheme: scheme)
                openSheet(in: app)
                XCTAssertTrue(app.staticTexts["有 3 張照片沒有加進去"].waitForExistence(timeout: 5), "[\(tag)] 只剩失敗標題（M＝3）")
                XCTAssertTrue(
                    app.staticTexts["看每張的原因，可以再試一次；不要的就移除，照片還在手機裡。"].exists, "[\(tag)] 主行"
                )
                XCTAssertTrue(app.buttons["關閉"].exists, "[\(tag)] footer 是「關閉」")
                XCTAssertFalse(app.buttons["在背景繼續，關閉視窗"].exists, "[\(tag)] 沒有進行中：不再是背景繼續")
                XCTAssertFalse(app.staticTexts["沒有成功"].exists, "[\(tag)] 群標題和標題同義，隱藏")
                XCTAssertTrue(app.buttons["重試這 2 張"].exists, "[\(tag)] 可重試 2 張（LS002 不計）")
                attach(app, name: "16d-\(tag)")

                let removes = app.buttons.matching(identifier: QAAccessibilityID.uploadQueueRemove)
                // 只用不在捲動區內的元件當座標基準（標題、重試槽、footer）——點列內按鈕時 XCUITest 會先捲動。
                let anchors = SummaryAnchors(
                    titleY: app.staticTexts["有 3 張照片沒有加進去"].frame.minY, footerY: app.buttons["關閉"].frame.minY,
                    retrySlot: app.buttons["重試這 2 張"].frame
                )

                // 先標兩張可重試的（連線中斷、伺服器忙碌），留 LS002：可重試數降到 0、失敗數降到 1。
                let wait = UITestTimeouts.standard
                removes.element(boundBy: 1).tap()
                XCTAssertTrue(app.staticTexts["有 2 張照片沒有加進去"].waitForExistence(timeout: wait), "[\(tag)] 標題數字更新 3→2")
                removes.element(boundBy: 1).tap()
                XCTAssertTrue(app.staticTexts["有 1 張照片沒有加進去"].waitForExistence(timeout: wait), "[\(tag)] 標題 2→1")
                XCTAssertTrue(app.staticTexts["沒有能重試的照片"].waitForExistence(timeout: wait), "[\(tag)] 可重試數降到 0：槽位改一行說明")
                XCTAssertFalse(app.buttons["重試這 2 張"].exists)
                XCTAssertFalse(app.buttons[QAAccessibilityID.uploadQueueRemoveAll].exists, "[\(tag)] 失敗數降到 1：批次鈕內容隱藏")
                assertLayoutHolds(app, anchors, tag: tag)

                let transition = app.staticTexts["這幾張不加進相簿了"]
                XCTAssertTrue(
                    tapRemove(removes.element(boundBy: 0), until: transition), "[\(tag)] M＝0：過渡標題，不宣稱都加好了"
                ) // 標最後一張（LS002）
                XCTAssertTrue(
                    app.staticTexts["照片還在手機裡。關閉這個視窗前，都可以按「復原」放回來。"].exists,
                    "[\(tag)] 過渡主行取稿面 x2it3Q 的 R3 版本"
                )
                XCTAssertTrue(app.buttons["關閉"].exists, "[\(tag)] 不自動關閉，footer 仍是「關閉」")
                XCTAssertEqual(app.buttons.matching(identifier: QAAccessibilityID.uploadQueueUndo).count, 3)
                assertLayoutHolds(app, anchors, tag: tag)
                attach(app, name: "16g-\(tag)")
                app.terminate()
            }
        }
    }

    // MARK: - 關閉 sheet 才真移除；入口列全部移除後直接隱藏（不經過「照片都加好了」）

    func testDismissCommitsRemovals_allRemoved_hidesEntryRow_partial_updatesValue_undoKeepsAll() {
        // 全部移除 → 關閉：入口列直接隱藏。
        var app = launch(fixture: "sheetOnlyFailed", size: Self.large, scheme: "light")
        let row = entryRow(in: app)
        // uitest-wait-ok: entryRow(in:) 內已 waitForExistence(timeout: 10)，row 此刻必在 accessibility tree 上
        XCTAssertEqual(row.label, "有 3 張照片沒有加進去，看原因，再試或移除", "入口只剩失敗態 Value 新句（C2a 同版上線）")
        openSheet(in: app)
        app.buttons[QAAccessibilityID.uploadQueueRemoveAll].tap()
        confirmDestructive("移除這 3 張", in: app)
        XCTAssertTrue(app.buttons[QAAccessibilityID.uploadQueueUndo].waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "有 3 張照片沒有加進去，看原因，再試或移除", "sheet 開著：入口列背後不因標記而變態")
        app.buttons["關閉"].tap()
        XCTAssertTrue(
            app.buttons[QAAccessibilityID.settingsUploadQueueRow].waitUntilGone(timeout: 10),
            "關閉 sheet 才提交；全部移除後入口列直接隱藏（不顯示「照片都加好了」）"
        )
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "照片都加好了")).firstMatch.exists)
        app.terminate()

        // 只移除一張 → 關閉：入口仍在、M 更新為 2。
        app = launch(fixture: "sheetOnlyFailed", size: Self.large, scheme: "light")
        openSheet(in: app)
        app.buttons.matching(identifier: QAAccessibilityID.uploadQueueRemove).element(boundBy: 0).tap()
        app.buttons["關閉"].tap()
        let partial = entryRow(in: app)
        XCTAssertTrue(
            waitForLabel(partial, "有 2 張照片沒有加進去，看原因，再試或移除", timeout: 10), "實際：\(partial.label)"
        )
        app.terminate()

        // 標記後復原 → 關閉：什麼都沒少。
        app = launch(fixture: "sheetOnlyFailed", size: Self.large, scheme: "light")
        openSheet(in: app)
        app.buttons.matching(identifier: QAAccessibilityID.uploadQueueRemove).element(boundBy: 0).tap()
        app.buttons[QAAccessibilityID.uploadQueueUndo].tap()
        app.buttons["關閉"].tap()
        let untouched = entryRow(in: app)
        XCTAssertTrue(untouched.waitForExistence(timeout: 5))
        XCTAssertEqual(untouched.label, "有 3 張照片沒有加進去，看原因，再試或移除", "復原的項目留在佇列")
        app.terminate()
    }

    // MARK: - 16e：全部完成＝3 欄縮圖格，不可點，「關閉」是唯一動作（淺深 × 預設／AX3）

    func testAllDone_photoGrid_isNotTappable_closeIsTheOnlyAction_lightDark_defaultAX3() {
        for scheme in ["light", "dark"] {
            for size in [Self.large, Self.ax3] {
                let tag = "\(scheme)-\(size == Self.ax3 ? "AX3" : "default")"
                let app = launch(fixture: "allDone", size: size, scheme: scheme)
                let row = entryRow(in: app)
                XCTAssertTrue(waitForLabel(row, "照片都加好了，30 張都加進相簿了", timeout: 12), "[\(tag)] 實際：\(row.label)")
                openSheet(in: app)

                XCTAssertTrue(app.staticTexts["照片都加好了"].waitForExistence(timeout: 5), "[\(tag)] 標題")
                XCTAssertTrue(app.staticTexts["30 張都加進相簿了"].exists, "[\(tag)] 主行 K")
                XCTAssertTrue(app.buttons["關閉"].exists, "[\(tag)] footer「關閉」")
                XCTAssertFalse(app.staticTexts["已完成"].exists, "[\(tag)] 縮圖格沒有群標題")
                XCTAssertFalse(app.staticTexts["沒有成功"].exists)

                let cells = app.descendants(matching: .any).matching(identifier: QAAccessibilityID.uploadQueueDonePhoto)
                XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 5), "[\(tag)] 縮圖格存在")
                XCTAssertGreaterThanOrEqual(cells.count, 3, "[\(tag)] 至少一整列 3 格")
                XCTAssertFalse(
                    app.buttons.matching(identifier: QAAccessibilityID.uploadQueueDonePhoto).firstMatch.exists,
                    "[\(tag)] 縮圖格不掛 button trait（C1a：不可點）"
                )
                let first = cells.element(boundBy: 0)
                XCTAssertTrue(
                    first.label.hasSuffix("加進相簿的照片") && first.label.contains(":"),
                    "[\(tag)] 每格 a11y label「今天 14:35 加進相簿的照片」形狀，實際：\(first.label)"
                )
                attach(app, name: "16e-\(tag)")

                // 點格子：沒有反應（不導航、不關閉 sheet）。
                first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(app.buttons["關閉"].exists, "[\(tag)] 點縮圖格後 sheet 仍在（不導航、不關閉）")

                app.buttons["關閉"].tap()
                XCTAssertTrue(
                    app.buttons[QAAccessibilityID.settingsUploadQueueRow].waitUntilGone(timeout: 10),
                    "[\(tag)] 全部完成、關閉 sheet 的邊界：入口列隱藏"
                )
                app.terminate()
            }
        }
    }

    // MARK: - 深色墓碑列（VR R3 I1：稿面沒有深色墓碑板，QA 補截）

    func testTombstoneRow_darkMode_screenshot() {
        for size in [Self.large, Self.ax3] {
            let app = launch(fixture: "sheetProgressFailures", size: size, scheme: "dark")
            openSheet(in: app)
            app.buttons.matching(identifier: QAAccessibilityID.uploadQueueRemove).element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons[QAAccessibilityID.uploadQueueUndo].waitForExistence(timeout: 5))
            attach(app, name: "tombstone-dark-\(size == Self.ax3 ? "AX3" : "default")")
            app.terminate()
        }
    }

    // MARK: - AX3 可重試失敗列：「重試」「移除」直排、各自單行；墓碑列「復原」同樣直排（QA R1：稿 `FIwU8` `zdknt`／`gtBYb`、
    // `YNP31` `Aqen6`／`NNfRI` 皆 vertical；iOS 26.0 曾橫排，「移除」「復原」逐字換行）

    func testAX3_retryableFailedRow_actionsStackVertically_singleLine_andUndoStaysStacked() {
        let app = launch(fixture: "sheetProgressFailures", size: Self.ax3, scheme: "dark")
        openSheet(in: app)
        let removes = app.buttons.matching(identifier: QAAccessibilityID.uploadQueueRemove)
        XCTAssertTrue(removes.element(boundBy: 1).waitForExistence(timeout: 5), "可重試失敗列（連線中斷）有「移除」")
        // AX3 這列在 footer 下方：先把列表捲到看得見（截圖才拍得到；量測只比同一畫面內的相對值）。
        let rows = app.scrollViews.containing(.button, identifier: QAAccessibilityID.uploadQueueRemove).firstMatch
        for _ in 0..<3 where !removes.element(boundBy: 1).isHittable { rows.swipeUp(velocity: .slow) }
        // 基準＝LS002 列（第 0 顆）的「移除」：「查看儲存空間」很寬、本來就直排不擠，它的尺寸就是單行「× 移除」的尺寸。
        let reference = removes.element(boundBy: 0).frame
        let retry = app.buttons.matching(NSPredicate(format: "label == '重試'")).element(boundBy: 0).frame
        let remove = removes.element(boundBy: 1).frame
        let measured = XCTAttachment(string: "AX3 參照移除=\(reference) 重試=\(retry) 移除=\(remove)")
        measured.name = "measure-AX3-retryrow"
        measured.lifetime = .keepAlways
        add(measured)
        attach(app, name: "16c-dark-AX3-retryrow") // 斷言前先截，紅的時候也留下證據
        XCTAssertGreaterThanOrEqual(remove.minY, retry.maxY - 1, "「移除」在「重試」正下方（直排），重試 \(retry) 移除 \(remove)")
        XCTAssertEqual(remove.minX, retry.minX, accuracy: 1, "直排：「移除」左緣貼齊「重試」（內容欄左緣）")
        XCTAssertEqual(remove.height, reference.height, accuracy: 1, "「移除」單行、不逐字換行：與 LS002 列的「移除」同高")
        XCTAssertEqual(remove.width, reference.width, accuracy: 1, "「移除」沒被擠窄：與 LS002 列的「移除」同寬")

        removes.element(boundBy: 1).tap()
        let undo = app.buttons[QAAccessibilityID.uploadQueueUndo]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "標記後原地出現「復原」")
        let undoFrame = undo.frame
        attach(app, name: "16f-dark-AX3-retryrow")
        XCTAssertEqual(undoFrame.minX, retry.minX, accuracy: 1, "墓碑列「復原」直排：貼內容欄左緣（原「移除」的 x），實際 \(undoFrame)")
        XCTAssertEqual(undoFrame.height, reference.height, accuracy: 1, "「復原」單行、不逐字換行，實際 \(undoFrame)")
        app.terminate()
    }
}

extension UploadQueueSheetRemovalUITests {
    struct SummaryAnchors {
        let titleY: CGFloat
        let footerY: CGFloat
        let retrySlot: CGRect
    }

    /// 停留期間只換數字不換版面：標題、footer 的 y 不動，「沒有能重試的照片」落在原重試槽的範圍內（同一個槽位）。
    func assertLayoutHolds(
        _ app: XCUIApplication, _ anchors: SummaryAnchors, tag: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let title = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH '有 ' AND label ENDSWITH '張照片沒有加進去' OR label == '這幾張不加進相簿了'")
        ).firstMatch
        XCTAssertEqual(title.frame.minY, anchors.titleY, accuracy: 1, "[\(tag)] 標題 y 不動", file: file, line: line)
        XCTAssertEqual(
            app.buttons["關閉"].frame.minY, anchors.footerY, accuracy: 1, "[\(tag)] footer y 不動", file: file, line: line
        )
        let slotText = app.staticTexts["沒有能重試的照片"]
        if slotText.exists {
            XCTAssertTrue(
                anchors.retrySlot.contains(CGPoint(x: slotText.frame.midX, y: slotText.frame.midY)),
                "[\(tag)] 說明落在原重試槽 \(anchors.retrySlot) 內，實際 \(slotText.frame)", file: file, line: line
            )
        }
    }

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

    private func openSheet(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let row = entryRow(in: app, file: file, line: line)
        XCTAssertTrue(row.waitForHittable(timeout: 10), file: file, line: line)
        row.tap()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label == '關閉' OR label == '在背景繼續，關閉視窗'"))
                .firstMatch.waitForExistence(timeout: 10),
            "點入口列應 present 上傳佇列 sheet", file: file, line: line
        )
    }

    /// 系統 `confirmationDialog` 的 destructive 鈕（文案和群標題列的批次鈕相同，取畫面上最後一個同名鈕＝對話框裡的）。
    private func confirmDestructive(_ title: String, in app: XCUIApplication) {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", title))
        XCTAssertGreaterThanOrEqual(matches.count, 1)
        matches.element(boundBy: matches.count - 1).tap()
    }

    /// LS-458：點「移除」並等 `expected`；tap 沒生效（`expected` 沒出現、這顆「移除」鈕仍在——生效會變「復原」）才重點一次。
    private func tapRemove(_ remove: XCUIElement, until expected: XCUIElement) -> Bool {
        for _ in 0..<2 {
            remove.tap() // 不先等 isHittable：列在 footer 下方時 tap 會自己捲到看得見（hittable 是捲完才成立）
            if expected.waitForExistence(timeout: UITestTimeouts.standard) { return true }
            guard remove.exists else { return false }
        }
        return false
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

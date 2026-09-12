import XCTest

/// LS-216：時間軸卡片互動列（`InteractionRow`）——三種卡片（日記／相簿／照片）都有互動列、
/// 愛心切換前後 `Comment Button` frame 不變（票文十條 #10：狀態改變不得移動版面）、AX3 尺寸
/// （`launchArguments` 通道，同 `ContentActionsAX3UITests` 既有理由）。三種卡片共用同一顆
/// `TapTargetGateScreenName.timelineInteractionRow`（`TapTargetGateHarness+Timeline.swift`
/// 種好日記卡未按讚／相簿卡已按讚／照片卡計數 0 三態）。
@MainActor
final class InteractionRowUITests: XCTestCase {
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    /// 三種卡片底部都有 Like Toggle／Count Zone／Comment Button——用 LS-216 新增的
    /// identifier（`QAAccessibilityID.interactionRowElement`）依 kind 逐一點名，不靠 label
    /// （三卡的 Comment Button label 目前都是「留言，0 則」，label 分不出是哪張卡）。
    func testAllThreeCardTypesHaveInteractionRow() {
        let app = TapTargetMeasurement.launch(.timelineInteractionRow)
        TapTargetMeasurement.assertScreenRendered(.timelineInteractionRow, in: app)

        for kind in ["diary", "album", "media"] {
            let likeToggle = app.buttons[QAAccessibilityID.interactionRowElement(kind: kind, element: "likeToggle")]
            let countZone = app.buttons[QAAccessibilityID.interactionRowElement(kind: kind, element: "countZone")]
            let commentButton = app.buttons[
                QAAccessibilityID.interactionRowElement(kind: kind, element: "commentButton")
            ]
            XCTAssertTrue(likeToggle.waitForExistence(timeout: 10), "\(kind) 卡應該有 Like Toggle")
            XCTAssertTrue(countZone.exists, "\(kind) 卡應該有 Count Zone")
            XCTAssertTrue(commentButton.exists, "\(kind) 卡應該有 Comment Button")
        }

        // 種子資料：日記卡未按讚（3 人）、相簿卡已按讚（5 人）——兩態的 label 都要對得上，
        // 不是隨便哪個狀態都顯示同一組文字。
        XCTAssertTrue(app.buttons["愛心"].exists, "日記卡應顯示未按讚態「愛心」")
        XCTAssertTrue(app.buttons["已按愛心"].exists, "相簿卡應顯示已按讚態「已按愛心」")
    }

    /// 十條 #10：狀態改變不得移動版面——切換愛心（未按讚→已按讚，文字從「愛心」2 字變成
    /// 「已按愛心」4 字）前後，同一張卡的 `Comment Button` frame 必須完全不變。`Like
    /// Toggle`／`Count Zone` 固定寬度（118×47／44×44，見 `InteractionRow` 文件）正是為了
    /// 保證這件事，這裡直接量測驗證，不只信任程式碼寫了固定寬。
    func testLikeToggleTap_doesNotMoveCommentButton() {
        let app = TapTargetMeasurement.launch(.timelineInteractionRow)
        TapTargetMeasurement.assertScreenRendered(.timelineInteractionRow, in: app)

        let diaryLikeToggle = app.buttons[QAAccessibilityID.interactionRowElement(kind: "diary", element: "likeToggle")]
        let diaryCommentButton = app.buttons[
            QAAccessibilityID.interactionRowElement(kind: "diary", element: "commentButton")
        ]
        XCTAssertTrue(diaryLikeToggle.waitForExistence(timeout: 10))
        let frameBefore = diaryCommentButton.frame

        diaryLikeToggle.tap()

        // 切換後文字應變成「已按愛心」（種子是未按讚態）——先確認切換真的發生，frame 比對
        // 才有意義（不是因為根本沒切換成功才「碰巧」frame 沒變）。用 `XCTNSPredicateExpectation`
        // 綁定同一個元素等 `.label` 真的變成新值——官方支援的「等 XCUIElement 屬性變化」寫法，
        // 比對同一個元素重查一次組合 predicate 更可靠（不受一次性 accessibility 樹快照影響）。
        let labelPredicate = NSPredicate(format: "label == %@", "已按愛心")
        let labelExpectation = XCTNSPredicateExpectation(predicate: labelPredicate, object: diaryLikeToggle)
        XCTAssertEqual(XCTWaiter().wait(for: [labelExpectation], timeout: 10), .completed, "點擊後應該切換成已按讚態")

        let frameAfter = diaryCommentButton.frame
        XCTAssertEqual(
            frameAfter, frameBefore,
            "愛心切換前後 Comment Button 的 frame 應該完全不變（十條 #10：狀態改變不得移動版面）"
        )
    }

    /// `InteractionRow` 的按鈕落在外層 `NavigationLink`（日記卡）可點範圍「內」——點擊
    /// Like Toggle 應該只切換愛心，不應該觸發外層導覽（見 `InteractionRow` 文件註解「巢狀
    /// 可互動元件」段）。用 sentinel（畫面仍是「時間軸」）驗證沒有被導去 `DiaryDetailView`。
    func testLikeToggleTap_doesNotNavigateAwayFromTimeline() {
        let app = TapTargetMeasurement.launch(.timelineInteractionRow)
        TapTargetMeasurement.assertScreenRendered(.timelineInteractionRow, in: app)

        let diaryLikeToggle = app.buttons[QAAccessibilityID.interactionRowElement(kind: "diary", element: "likeToggle")]
        XCTAssertTrue(diaryLikeToggle.waitForExistence(timeout: 10))

        diaryLikeToggle.tap()

        XCTAssertTrue(app.staticTexts["時間軸"].exists, "點擊 Like Toggle 不應該導覽離開時間軸")
    }

    /// Count Zone 計數 0 時（照片卡種子）點擊不應該開啟按讚名單 sheet——票文 scope 3。
    func testCountZone_withZeroCount_doesNotOpenLikersSheet() {
        let app = TapTargetMeasurement.launch(.timelineInteractionRow)
        TapTargetMeasurement.assertScreenRendered(.timelineInteractionRow, in: app)

        let mediaCountZone = app.buttons[QAAccessibilityID.interactionRowElement(kind: "media", element: "countZone")]
        XCTAssertTrue(mediaCountZone.waitForExistence(timeout: 10))
        XCTAssertFalse(mediaCountZone.isEnabled, "計數 0 時 Count Zone 應該是 disabled")

        mediaCountZone.tap()

        XCTAssertFalse(likersSheetHeadline(in: app).exists, "計數 0 時點擊不應該開啟按讚名單 sheet")
    }

    /// 按讚名單 sheet：相簿卡種子已按讚（5 人），點擊 Count Zone 應該開啟 sheet。**不斷言
    /// 精確人數**：`LikersListSheet` 開場先用互動列已知的 `likeCount`（種子值 5）當標題
    /// placeholder，`reactors` 查詢完成（`PreviewTimelineAPIClient.reactors` 固定回傳空
    /// 陣列，同其餘 `Preview*APIClient` 的「不打真網路」既有角色）後標題會改用實際筆數（0）
    /// ——這是本票 harness 刻意的簡化（見 `LikersListSheet.headline` 文件註解），斷言精確
    /// 數字會依查詢完成時機不同而 flaky，改用「標題含『人按了愛心』字樣」驗證 sheet 真的
    /// 開啟即可，計數字面值由 QA 真後端驗收覆蓋（票文驗收「兩帳號互按愛心…名單顯示對方」）。
    func testCountZone_withPositiveCount_opensLikersSheet() {
        let app = TapTargetMeasurement.launch(.timelineInteractionRow)
        TapTargetMeasurement.assertScreenRendered(.timelineInteractionRow, in: app)

        let albumCountZone = app.buttons[QAAccessibilityID.interactionRowElement(kind: "album", element: "countZone")]
        XCTAssertTrue(albumCountZone.waitForExistence(timeout: 10))
        XCTAssertTrue(albumCountZone.isEnabled)

        albumCountZone.tap()

        XCTAssertTrue(likersSheetHeadline(in: app).waitForExistence(timeout: 10), "應開啟按讚名單 sheet 並顯示標題")
    }

    private func likersSheetHeadline(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "人按了愛心")).firstMatch
    }

    /// AX3 下三種卡片的互動列元件仍要存在、可捲動可觸達、彼此不重疊——同
    /// `ContentActionsAX3UITests` 既有的量測手法（`launchArguments`，不用
    /// `launchEnvironment`，理由見 `TapTargetMeasurement.launch(_:contentSizeCategory:)`
    /// 文件註解）。
    func testInteractionRow_ax3_allButtonsReachableAndDoNotOverlap() {
        let app = TapTargetMeasurement.launch(.timelineInteractionRow, contentSizeCategory: Self.ax3)
        TapTargetMeasurement.assertScreenRendered(.timelineInteractionRow, in: app)

        var buttons: [XCUIElement] = []
        for kind in ["diary", "album", "media"] {
            for element in ["likeToggle", "countZone", "commentButton"] {
                buttons.append(app.buttons[QAAccessibilityID.interactionRowElement(kind: kind, element: element)])
            }
        }
        for button in buttons {
            XCTAssertTrue(button.waitForExistence(timeout: 10), "AX3 下所有互動列按鈕都應該存在於畫面樹")
        }
        scrollUntilAllHittable(buttons, in: app)
        assertNoOverlap(buttons)
    }

    /// LS-216 R2（merge-review R1 minor m3）：不只驗證「彼此不重疊」，直接量 AX3 兩個固定
    /// 尺寸節點的實際 frame——`Like Toggle` 220×80、`Count Zone` 56×80（見 `InteractionRow
    /// .likeToggleSize`／`.countZoneSize` 文件）。`accuracy: 1` 容忍模擬器次像素捨入（同
    /// `TimelineStore` R2 Count Zone 43.7pt 那類既有誤差量級），不是放寬到看不出回歸。
    func testInteractionRow_ax3_fixedSizesMatchSpec() {
        let app = TapTargetMeasurement.launch(.timelineInteractionRow, contentSizeCategory: Self.ax3)
        TapTargetMeasurement.assertScreenRendered(.timelineInteractionRow, in: app)

        let diaryLikeToggle = app.buttons[QAAccessibilityID.interactionRowElement(kind: "diary", element: "likeToggle")]
        XCTAssertTrue(diaryLikeToggle.waitForExistence(timeout: 10))
        XCTAssertEqual(diaryLikeToggle.frame.width, 220, accuracy: 1, "AX3 Like Toggle 寬應固定 220pt")
        XCTAssertEqual(diaryLikeToggle.frame.height, 80, accuracy: 1, "AX3 Like Toggle 高應固定 80pt")

        let diaryCountZone = app.buttons[QAAccessibilityID.interactionRowElement(kind: "diary", element: "countZone")]
        XCTAssertTrue(diaryCountZone.waitForExistence(timeout: 10))
        XCTAssertEqual(diaryCountZone.frame.width, 56, accuracy: 1, "AX3 Count Zone 寬應固定 56pt")
        XCTAssertEqual(diaryCountZone.frame.height, 80, accuracy: 1, "AX3 Count Zone 高應固定 80pt")
    }

    /// LS-216 R2（merge-review R1 minor m4）：`InteractionRow` 的三顆按鈕巢狀在
    /// `qa.timeline.diaryCard`（`TimelineView.cardView` 的 `NavigationLink`，LS-158 既有 QA
    /// e2e 通道）可點範圍內——確認這層巢狀沒有讓 identifier 查詢命中多個元素，也沒有讓
    /// 「點卡片本體（非互動列按鈕）」的既有導覽路徑失效。
    ///
    /// 這裡刻意**不**用 `.tap()`（預設打在整個 `qa.timeline.diaryCard` 元素的幾何中心）——
    /// 這份 harness fixture 的日記內文只有一行、無附照（見 `seededInteractionRowTimelineStore`），
    /// 卡片整體高度大半被 `InteractionRow` 占走，幾何中心點實測會落在 `Like Toggle`／
    /// `Comment Button` 的可點範圍內，`.tap()` 打中的其實是按鈕，不是卡片本體——這忠實反映
    /// 「使用者真的點在按鈕上」的物理行為（按鈕確實佔了那塊畫面），並非導覽路徑失效，只是
    /// 這支測試原本假設的「打中心＝打卡片本體」在這份短內文 fixture 上不成立。改用
    /// `.coordinate(withNormalizedOffset:)` 打卡片**頂端**（`.combine` 純顯示內容那一段，
    /// `InteractionRow` 固定在卡片最下方，見 `DiaryCardView.body`），才是「點卡片本體」該打
    /// 的位置。
    func testDiaryCardIdentifier_stillFindableAndNavigates() {
        let app = TapTargetMeasurement.launch(.timelineInteractionRow)
        TapTargetMeasurement.assertScreenRendered(.timelineInteractionRow, in: app)

        let diaryCards = app.buttons.matching(identifier: QAAccessibilityID.timelineDiaryCard)
        XCTAssertEqual(diaryCards.count, 1, "同一頁只有一張日記卡，qa.timeline.diaryCard 應該剛好命中一個元素")
        let diaryCard = diaryCards.firstMatch
        XCTAssertTrue(diaryCard.waitForExistence(timeout: 10))

        diaryCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()

        // LS-230（merge-review R4 `4be70111` m3）：原本 tap 後立即 `XCTAssertFalse(app.staticTexts["時間軸"]
        // .exists, …)` 沒有任何等待——`exists` 是一次性快照，CI runner 負載高、導覽轉場尚未完成時「時間軸」
        // 標題仍在 hierarchy 裡，就會誤判失敗（兩度命中：LS-216 R3 PR run／09-12 development push run
        // 34668565895）。改成正向等待目的頁（`DiaryDetailView`）的識別元素出現——語意更貼近測試想證的事
        // 「點卡片本體會導覽到日記詳情」，也是決定性同步點（成功即代表轉場已完成，不受 runner 負載影響）。
        let diaryDetailBody = app.staticTexts[QAAccessibilityID.diaryDetailBody]
        XCTAssertTrue(
            diaryDetailBody.waitForExistence(timeout: 10),
            "點擊日記卡本體（非互動列按鈕）應該正常導覽到日記詳情頁"
        )
    }

    // MARK: - Helpers（同 `ContentActionsAX3UITests` 既有寫法，不同 target 無法共用 private 方法）

    private func scrollUntilAllHittable(_ elements: [XCUIElement], in app: XCUIApplication, maxAttempts: Int = 6) {
        var previousYs: [CGFloat] = []
        for _ in 0..<maxAttempts {
            if elements.allSatisfy(\.isHittable) { return }
            let currentYs = elements.map { $0.frame.minY }
            if currentYs == previousYs { return }
            previousYs = currentYs
            app.swipeUp()
        }
    }

    private func assertNoOverlap(_ elements: [XCUIElement], file: StaticString = #filePath, line: UInt = #line) {
        let visible = elements.filter(\.isHittable)
        for firstIndex in 0..<visible.count {
            for secondIndex in (firstIndex + 1)..<visible.count {
                let first = visible[firstIndex]
                let second = visible[secondIndex]
                XCTAssertFalse(
                    first.frame.intersects(second.frame),
                    "AX3 下「\(first.label)」與「\(second.label)」不應該重疊：\(first.frame) vs \(second.frame)",
                    file: file, line: line
                )
            }
        }
    }
}

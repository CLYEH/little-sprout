import XCTest

/// LS-246（票文範圍 1，池 `8a00311d` i3）：`DiaryDetailView` 影片 `fullScreenCover` 併入
/// `activeSheet` 單一互斥狀態之後，這裡驗證兩個真正會受影響的情境（見 `DiaryDetailView.swift`
/// 檔頭 LS-246 文件註解）：
///
/// 1. 「留言 sheet 開著時點影片」——`playVideo()` 先 tap、簽名 URL 回來才設狀態；如果簽名
///    回來時留言 sheet 恰好也已經被觸發開啟，晚到的影片必須正確接手（把留言 sheet 收起、換成
///    全螢幕播放器），不是被系統忽略或兩者同時呈現。`.diaryDetailWithVideo` harness（見
///    `TapTargetGateHarness+Safety.swift`）用 `signDelayNanoseconds: 3_000_000_000` 讓「點
///    影片、簽名回來」之間有個穩定的窗口——這裡先點影片（啟動非同步簽名）、緊接著點留言鈕
///    （此時還沒有任何東西呈現，留言鈕點得到），留言 sheet 應該先正確開啟；接著等簽名回來，
///    畫面應該換成影片全螢幕。
///
///    **斷言選型說明（R1 實測踩過的坑）**：一開始想斷言「`interactionRow` 的留言鈕從
///    accessibility tree 消失」佐證 `fullScreenCover` 蓋滿全螢幕——實測發現 SwiftUI 的
///    `.fullScreenCover` **不會**把背景內容從 XCUITest 的 accessibility 快照移除（`exists`
///    仍回 `true`，即使畫面上完全看不到、點不到），跟 `.sheet` 真正 dismiss 後內容確實消失
///    的行為不同（本檔 debug 探針實測：`moreButton.exists` 在影片呈現後 4.5 秒仍是 `true`，
///    `UnsupportedContentIndicator` 則精準在延遲的第 3 秒從 `false` 轉 `true`）。改成斷言
///    `UnsupportedContentIndicator`（`AVPlayerViewController` 內容載入失敗態下唯一穩定、且
///    只有影片全螢幕真的呈現時才會出現的元素，harness 用假 URL 必定載入失敗）——這是正向存在
///    斷言，不是脆弱的「背景元素消失」負向斷言。
/// 2. 「影片全螢幕關閉後點『⋯』」——AVKit 播放器本身有系統原生的「關閉」鈕（`Close Button`，
///    點一下畫面內容區才會浮現控制列，同真實使用者操作），關閉後應該正確回到 `DiaryDetailView`
///    並且「⋯」仍能正確開出內容操作表，不會因為剛才影片用過同一個 `activeSheet` 而卡住。
@MainActor
final class DiaryDetailVideoUITests: XCTestCase {
    func testVideoTap_whileCommentsSheetOpen_videoTakesOverCorrectly() {
        let app = TapTargetMeasurement.launch(.diaryDetailWithVideo)
        TapTargetMeasurement.assertScreenRendered(.diaryDetailWithVideo, in: app)

        let videoTile = app.buttons["影片 0:05，點兩下播放"]
        XCTAssertTrue(videoTile.waitForExistence(timeout: 10), "詳情頁瀑布流應該有一支可播放的影片格")
        videoTile.tap()

        // 影片簽名仍在飛行中（harness 種了 3 秒延遲，見 `diaryDetailWithVideoHost` 文件註解）
        // ——這時候還沒有任何東西呈現，留言鈕點得到，留言 sheet 應該正確開啟。
        let commentButton = app.buttons[
            QAAccessibilityID.interactionRowElement(kind: "diary", element: "commentButton")
        ]
        XCTAssertTrue(commentButton.waitForExistence(timeout: 2), "影片簽名完成前，詳情頁本體應該還在、留言鈕應該點得到")
        commentButton.tap()

        let emptyStateText = app.staticTexts["還沒有人留言"]
        XCTAssertTrue(emptyStateText.waitForExistence(timeout: 2), "應該先正確呈現留言 sheet")

        // 等影片簽名回來接手——見上方文件註解，用 `UnsupportedContentIndicator` 的正向存在
        // 斷言，不是背景元素消失的負向斷言。timeout 8 秒：留給 3 秒延遲＋前面幾步 XCUITest
        // 動作本身的耗時餘裕。
        let videoIndicator = app.images["UnsupportedContentIndicator"]
        XCTAssertTrue(videoIndicator.waitForExistence(timeout: 8), "影片簽名回來後應該正確接手、呈現影片全螢幕")
        XCTAssertTrue(
            waitForNonExistence(emptyStateText, timeout: 3),
            "影片全螢幕接手後，留言 sheet 應該已經被收起（是換掉，不是疊在旁邊）"
        )
    }

    func testVideoFullScreen_afterClosing_moreButtonOpensContentActionsCorrectly() {
        let app = TapTargetMeasurement.launch(.diaryDetailWithVideo)
        TapTargetMeasurement.assertScreenRendered(.diaryDetailWithVideo, in: app)

        let videoTile = app.buttons["影片 0:05，點兩下播放"]
        XCTAssertTrue(videoTile.waitForExistence(timeout: 10), "詳情頁瀑布流應該有一支可播放的影片格")
        videoTile.tap()

        // `videoTile` 點下後仍要等 harness 種的 3 秒延遲（見 `diaryDetailWithVideoHost` 文件
        // 註解）簽名回來才會真的呈現全螢幕播放器；`UnsupportedContentIndicator` 見上一支測試
        // 文件註解的斷言選型說明。
        let videoIndicator = app.images["UnsupportedContentIndicator"]
        XCTAssertTrue(videoIndicator.waitForExistence(timeout: 8), "影片簽名回來後應該正確呈現全螢幕播放器")

        // AVKit 播放器控制列預設收起，點一下內容區才會浮現（同真實使用者操作）。
        videoIndicator.tap()

        let closeButton = app.buttons["關閉"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "點一下內容區應該浮現播放器控制列，包含系統原生的關閉鈕")
        closeButton.tap()

        let moreButton = app.buttons["更多操作"]
        XCTAssertTrue(waitForNonExistence(videoIndicator, timeout: 5), "關閉影片後全螢幕播放器應該已經收起")
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5), "關閉影片後應該回到詳情頁本體，看得到「更多操作」")
        moreButton.tap()

        XCTAssertTrue(
            app.staticTexts["「今天在溜滑梯上玩得好開心。」"].waitForExistence(timeout: 5),
            "影片全螢幕關閉後點「⋯」應該正確呈現內容操作表——不應該因為剛才影片用過同一個 activeSheet 而卡住"
        )
    }

    /// `XCTNSPredicateExpectation` 等「停止存在」——同 `SettingsViewIPadTests`／
    /// `DiaryDetailCommentsUITests` 既有的 `waitForNonExistence` helper（LS-237 第 8 項教訓：
    /// 一次性 `.exists` 快照在關閉動畫還沒跑完的瞬間可能誤判成「還在」）。這裡只用在真正會被
    /// 移除的元素上（`.sheet` 內容、`fullScreenCover` 本身），不用在 `fullScreenCover` 背景的
    /// 元素——見上方文件註解，那類元素 `.exists` 不會轉 `false`。
    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

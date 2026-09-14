import XCTest

/// LS-246（票文範圍 1，池 `8a00311d` i3）：`DiaryDetailView` 影片 `fullScreenCover` 併入
/// `activeSheet` 單一互斥狀態之後，這裡驗證兩個真正會受影響的情境（見 `DiaryDetailView.swift`
/// 檔頭 LS-246 文件註解）：
///
/// 1. 「留言 sheet 開著時點影片」——`playVideo()` 先 tap、簽名 URL 回來才設狀態；如果簽名
///    回來時留言 sheet 恰好也已經被觸發開啟，晚到的影片必須正確接手（把留言 sheet 收起、換成
///    全螢幕播放器），不是被系統忽略或兩者同時呈現。`.diaryDetailWithVideo` harness（見
///    `TapTargetGateHarness+DiaryDetailVideo.swift`）用可控的簽名延遲（預設 3 秒，情境 1 覆寫
///    為 8 秒，見下方 LS-268 補充）讓「點影片、簽名回來」之間有個穩定的窗口——這裡先點影片
///    （啟動非同步簽名）、緊接著點留言
///    鈕（此時還沒有任何東西呈現，留言鈕點得到），留言 sheet 應該先正確開啟；接著等簽名回來，
///    畫面應該換成影片全螢幕。
/// 2. 「影片全螢幕關閉後點『⋯』」——AVKit 播放器本身有系統原生的「關閉」鈕，關閉後應該正確
///    回到 `DiaryDetailView` 並且「⋯」仍能正確開出內容操作表，不會因為剛才影片用過同一個
///    `activeSheet` 而卡住。
///
/// **LS-268（池 `0d0005c4`，CI xcresult 時間軸查證 `99fb1019`）**：情境 1 原本吃 harness 預設的
/// 3 秒簽名延遲，慢 CI runner 上「wait for app to idle」異常耗時（實測 2.46 秒）會吃掉緩衝
/// 視窗，讓存在性檢查前簽名已到期、假紅。改用 `-LSVideoSignDelaySeconds 8`（見
/// `TapTargetGateHarness+DiaryDetailVideo.swift`）把這個情境的窗口拉大到 8 秒，留給慢機餘裕；
/// 情境 2 不依賴這個窗口內完成互動，維持預設 3 秒。
///
/// **R2（dev CI run `34743983632` FAIL 根因修正，非猜測——逐行核對 xcresult
/// `test-results activities` 時間軸）**：R1 版本 `signedURL` 指向假的
/// `https://example.com/harness-video.mp4`——這個網域*真的能連上*（IANA 保留測試網域，回一個
/// HTML 頁面），`AVPlayer` 因此把它當成「內容存在但格式不支援」（`UnsupportedContentIndicator`），
/// 在 dev CI（iOS 26.2）上這個狀態維持數秒後**系統自己把整個呈現關掉**——`關閉` 鈕的
/// `waitForExistence(timeout: 5)` 確認存在（通過）後、`.tap()` 內部重新尋找元素的 1–3 秒窗口
/// 內 `fullScreenCover` 已經消失，最終回報「找不到『關閉』」，此時畫面已經是 `DiaryDetailView`
/// 本體。本機 iOS 26.0 沒有重現；是 iOS 26.2 上 AVKit 對「內容不支援」狀態的自動收起時機
/// 差異，**不是**本票互斥邏輯（`sheetBinding`／`videoBinding`）的缺陷——失敗發生在
/// `activeSheet` 已經正確等於 `.video(...)` 之後，是 AVKit 自己把呈現關掉，不是被留言
/// sheet／內容操作表搶走。改用 `TapTargetGateHarness+DiaryDetailVideo.swift` 本機合成的真實
/// 可播放影片（見該檔文件註解）——真正有效的內容不會進入「不支援」狀態，不會觸發那個自動
/// 收起行為。另外兩處收斂：(1) 點影片鈕前先確認 `hittable`（不只是 `exists`）；(2) 找「關閉」
/// 鈕改用有界重試（`waitForCloseButtonAppearing`，最多 3 次、每次 10 秒）——AVKit 控制列
/// 「一開始就浮現」與「需要先點一下內容區才浮現」兩種情況都收斂，不預先假設是哪一種。
@MainActor
final class DiaryDetailVideoUITests: XCTestCase {
    func testVideoTap_whileCommentsSheetOpen_videoTakesOverCorrectly() {
        // LS-268：8 秒延遲（預設 3 秒），慢 CI runner 上排程延遲（如「wait for app to idle」）
        // 才不會吃光緩衝視窗（見檔頭 LS-268 補充）。
        // LS-269（池 `3e9347c4` (2) m2）：`signDelaySeconds` 連清單縮圖簽名也一起睡，所以延遲
        // 拉大會把 `videoTile` 第一次出現的時間等比往後推——固定 10 s timeout 因此隨延遲增加而
        // 被吃掉緩衝（延遲 3→8 s 時餘裕從 8.9 s 縮到 3.9 s）。改成「基準 7 s（原本 10 s 對應
        // 預設 3 s 延遲的餘裕）＋延遲秒數」，timeout 隨延遲等比放大、餘裕維持恆定。
        let signDelaySeconds = 8
        let videoTileTimeout = TimeInterval(7 + signDelaySeconds)
        let app = TapTargetMeasurement.launch(
            .diaryDetailWithVideo, contentSizeCategory: "UICTContentSizeCategoryL",
            extraLaunchArguments: ["-LSVideoSignDelaySeconds", String(signDelaySeconds)]
        )
        TapTargetMeasurement.assertScreenRendered(.diaryDetailWithVideo, in: app)

        let videoTile = app.buttons["影片 0:05，點兩下播放"]
        XCTAssertTrue(videoTile.waitForExistence(timeout: videoTileTimeout), "詳情頁瀑布流應該有一支可播放的影片格")
        XCTAssertTrue(videoTile.waitForHittable(timeout: videoTileTimeout), "影片格應該是可點擊狀態，不只是存在")
        videoTile.tap()

        // 影片簽名仍在飛行中（harness 種了 8 秒延遲，見本檔 LS-268 補充）——這時候還沒有任何
        // 東西呈現，留言鈕點得到，留言 sheet 應該正確開啟。
        let commentButton = app.buttons[
            QAAccessibilityID.interactionRowElement(kind: "diary", element: "commentButton")
        ]
        XCTAssertTrue(commentButton.waitForExistence(timeout: 2), "影片簽名完成前，詳情頁本體應該還在、留言鈕應該點得到")
        commentButton.tap()

        let emptyStateText = app.staticTexts["還沒有人留言"]
        XCTAssertTrue(emptyStateText.waitForExistence(timeout: 2), "應該先正確呈現留言 sheet")

        // 等影片簽名回來接手——`.sheet` 真的 dismiss 後內容確實從 accessibility tree 消失
        // （跟背景元素在 `fullScreenCover` 蓋上後仍持續 `exists` 不同，見檔頭 R2 補充）。
        // timeout 10 秒：留給 8 秒延遲＋前面幾步 XCUITest 動作本身的耗時餘裕。
        XCTAssertTrue(
            emptyStateText.waitUntilGone(timeout: 10), "影片簽名回來後應該把留言 sheet 收起，換成影片全螢幕"
        )

        // 進一步確認「收起的是換成影片全螢幕」而不是其他非預期狀態——有界重試找系統原生
        // 「關閉」鈕（見檔頭文件註解），找得到就是真的在播放器畫面上。
        let closeButton = app.buttons["關閉"]
        XCTAssertTrue(
            waitForCloseButtonAppearing(closeButton, in: app),
            "留言 sheet 收起後應該是換成影片全螢幕（找得到系統原生的關閉鈕）"
        )
    }

    func testVideoFullScreen_afterClosing_moreButtonOpensContentActionsCorrectly() {
        let app = TapTargetMeasurement.launch(.diaryDetailWithVideo)
        TapTargetMeasurement.assertScreenRendered(.diaryDetailWithVideo, in: app)

        let videoTile = app.buttons["影片 0:05，點兩下播放"]
        XCTAssertTrue(videoTile.waitForExistence(timeout: 10), "詳情頁瀑布流應該有一支可播放的影片格")
        XCTAssertTrue(videoTile.waitForHittable(timeout: 10), "影片格應該是可點擊狀態，不只是存在")
        videoTile.tap()

        // `videoTile` 點下後仍要等 harness 種的 3 秒延遲（見 `diaryDetailWithVideoHost` 文件
        // 註解）簽名回來才會真的呈現全螢幕播放器；AVKit 控制列可能一開始就浮現、也可能需要先
        // 點一下內容區才浮現——見檔頭文件註解的有界重試。
        let closeButton = app.buttons["關閉"]
        XCTAssertTrue(waitForCloseButtonAppearing(closeButton, in: app), "應該正確呈現全螢幕播放器＋系統原生的關閉鈕")
        closeButton.tap()

        let moreButton = app.buttons["更多操作"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5), "關閉影片後應該回到詳情頁本體，看得到「更多操作」")
        moreButton.tap()

        XCTAssertTrue(
            app.staticTexts["「今天在溜滑梯上玩得好開心。」"].waitForExistence(timeout: 5),
            "影片全螢幕關閉後點「⋯」應該正確呈現內容操作表——不應該因為剛才影片用過同一個 activeSheet 而卡住"
        )
    }

    /// AVKit 控制列（含系統原生「關閉」鈕）可能一開始就浮現、也可能需要先點一下內容區才浮現
    /// （且會在數秒後自動再收起）——有界重試：先直接等一下關閉鈕，等不到才點一次畫面中央
    /// 再重試，不預先假設是哪一種情況。見檔頭文件註解 R2 根因分析（dev CI run
    /// `34743983632`）；點畫面中央用座標（不用元素參照）——控制列收起時沒有可穩定取到的
    /// 元素代表內容區。
    private func waitForCloseButtonAppearing(
        _ closeButton: XCUIElement, in app: XCUIApplication, maxAttempts: Int = 3, timeoutPerAttempt: TimeInterval = 10
    ) -> Bool {
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for attempt in 1...maxAttempts {
            if closeButton.waitForExistence(timeout: timeoutPerAttempt) { return true }
            if attempt < maxAttempts { center.tap() }
        }
        return false
    }
}

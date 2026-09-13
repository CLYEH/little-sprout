import XCTest

// MARK: - 瀏覽（LS-260；獨立成 extension 避免主 class body 超過 SwiftLint type_body_length）
//
// LS-260（LS-96 池項 `6b87b252`）修 tap-y 公式缺口、加上安全帶計算與捲動重試之後，`QADriver.swift`
// 同時超過 SwiftLint `file_length`（400）與 `type_body_length`（250）上限——比照
// `QADriver+LoginLanding.swift`（LS-220）既有先例把「瀏覽」整段搬到獨立檔案，搬移本身不改行為。
// 搬出去後這段仍要呼叫主檔的 `attachText`，該 helper 的 `private` 因此拿掉（預設 `internal`，同
// target 內可見、對外仍不公開），同 LS-220 對 `landingCandidates` 的處理。`qa_driver_gate_check.py`
// 掃的是 `LittleSproutUITests/QA/QADriver*.swift` glob，本檔天然涵蓋在內（自測 ⑬ 釘住這件事）。
extension QADriver {
    /// 時間軸沒有任何日記卡（空狀態）就先發一篇純文字日記當瀏覽對象——`browse` 不依賴先跑過 `publish`。
    func seedDiaryIfTimelineEmpty() throws {
        if diaryCards.firstMatch.waitForExistence(timeout: 10) { return }
        try openEditor()
        let body = "LS-158 browse seed \(Self.stamp())"
        try typeDiaryBody(body)
        try publishAndWaitForCard(body: body)
    }

    /// 算出「點得到日記卡、又不會誤點浮動 Tab Bar」的絕對座標。
    ///
    /// LS-220 實測踩到：`publish` 留下的影片＋照片＋日記三張卡讓日記卡排到最後，卡片幾何中心落在浮動
    /// Tab Bar 範圍內，`isHittable == true` 但 `.tap()` 誤點成「寶貝」分頁鈕；當時的公式是
    /// `max(cardFrame.minY + 8, min(cardFrame.midY, tabBarFrame.minY - 24))`。
    ///
    /// LS-260（LS-96 池項 `6b87b252`）修掉那條公式的缺口：卡片**整張**落在 Tab Bar 頂緣以下時，外層的
    /// `max(cardFrame.minY + 8, …)` 會把算好的安全 y 再推回 Tab Bar 帶裡——LS-246 QA 實測
    /// `card.frame=(18.7, 802.3, 365.0, 285.3)`、`tabBar.frame=(112, 782, 88, 52)`：安全 y 算出 758，
    /// 卻被下限 810.3 蓋掉，正好落在 Tab Bar 的 782–834 帶，x=201.2 又壓在「相簿」「寶貝」兩鈕交界，
    /// 於是點成「寶貝」分頁（證據 `browse-07-fail.png` 停在寶貝頁，兩次皆同）。
    ///
    /// 改法：先求「卡片」與「Tab Bar 頂緣以上（留 24pt 緩衝）」的交集帶，帶是空的＝卡片被 Tab Bar 蓋住
    /// ／還在畫面外，往上捲一段再重算；捲 `cardScrollAttempts` 次仍是空的就大聲失敗——不再退而求其次
    /// 猜一個落在 Tab Bar 上的座標。每一輪的卡片／Tab Bar frame 與安全帶都附進 xcresult。
    private func safeCardTapPoint(card: XCUIElement) throws -> CGPoint {
        for attempt in 0...Self.cardScrollAttempts {
            let cardFrame = card.frame
            // LS-220 merge-review R2 n4：讀 `.frame` 前先 `require`，同 `browseDetailAndAlbums()` 後段慣例。
            let what = "Tab Bar「相簿」（讀 frame 算避開浮動 Tab Bar 的點擊 y）"
            let tabBarFrame = try require(app.buttons["相簿"], what).frame
            let top = cardFrame.minY + 8
            let bottom = min(cardFrame.maxY - 8, tabBarFrame.minY - 24)
            attachText(
                "attempt=\(attempt) card.frame=\(cardFrame) tabBar.frame=\(tabBarFrame) safeBand=[\(top), \(bottom)]",
                name: "diary-card-tap-coordinates"
            )
            if bottom >= top {
                return CGPoint(x: cardFrame.midX, y: min(max(cardFrame.midY, top), bottom))
            }
            guard attempt < Self.cardScrollAttempts else { break }
            // LS-260 R2 m2（merge-review R1）：捲不動的判定改看「卡片 frame 有沒有動」，不再依賴
            // `snap()` 的跨步驟 streak。原寫法有一個會**反過來咬自己**的交互：streak 是全域計數，
            // 若進迴圈前已經有兩張逐字相同的截圖（`landed-timeline` → `ensureFamily` 的 `timeline`，
            // 中間只有幾秒、狀態列分鐘沒跳就會相同——正是 `snap()` 註解自己舉的例子），第一次
            // attempt 的 `snap` 就把 streak 推到 3 而 `XCTFail`：連一次 `swipeUp()` 都還沒發生，
            // 捲動重試等於沒生效；而且 `continueAfterFailure = false`（`QASmokeTests.swift`）會讓
            // 下面的 `attachHierarchy`／`snap("fail")`／詳細訊息全部不執行，診斷比修之前更差。
            // 修法：進迴圈就把 streak 歸零（本迴圈自己的截圖才互相比），再用 frame 位移直接判定。
            resetScreenStreak()
            snap("card-under-tabbar")
            app.swipeUp()
            let movedFrame = card.frame
            guard movedFrame.minY != cardFrame.minY else {
                attachHierarchy(reason: "diary-card-scroll-stuck")
                snap("fail")
                XCTFail(
                    "時間軸日記卡整張落在浮動 Tab Bar 頂緣以下，往上捲之後 card.frame 完全沒動"
                    + "（minY 仍是 \(cardFrame.minY)）——時間軸捲不動，不再重試；座標附件已在 xcresult"
                )
                throw QAFailure.screen("時間軸日記卡（捲不動）")
            }
        }
        attachHierarchy(reason: "diary-card-under-tabbar")
        snap("fail")
        XCTFail(
            "時間軸日記卡整張都落在浮動 Tab Bar 頂緣以下，往上捲 \(Self.cardScrollAttempts) 次後仍找不到"
            + "可點擊的安全區——各輪的卡片／Tab Bar frame 與安全帶已附在 xcresult"
        )
        throw QAFailure.screen("時間軸日記卡（可點擊的安全區）")
    }

    /// `safeCardTapPoint` 找不到安全帶時往上捲幾次；捲完仍沒有就失敗。
    private static let cardScrollAttempts = 3

    /// 日記卡→詳情（內文＋照片牆）→返回→相簿分頁→時間軸分頁。
    func browseDetailAndAlbums() throws {
        let card = try require(diaryCards.firstMatch, "時間軸日記卡", timeout: 20)
        let tapPoint = try safeCardTapPoint(card: card)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: tapPoint.x, dy: tapPoint.y)).tap()
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

import XCTest

/// LS-343（實機回報：iPhone 12 Pro 390pt、預設字級，Header「新增回憶」被壓成一字一行、膠囊
/// 變成高瘦橢圓）——現有 tap-target gate（`TapTargetMeasurement.violations`）只驗最短邊
/// ≥44pt，換行壓縮成直排之後熱區反而「變高」，不會被那支既有檢查抓到（見該檔文件註解），這正是
/// LS-315 在 402pt 機型驗收時漏網的原因。這裡額外驗「鈕寬 ≥ 鈕高」（不是被壓成直排的瘦長膠囊）
/// 與「高度落在單行範圍內」（換行成多行文字會把高度撐到遠超單行）。
///
/// **390pt／375pt 兩支已知限制（誠實記錄，不是可以忽略的雜訊）**：本機可用的模擬器 runtime
/// （iOS 26.x，釘住版 26.2 本機沒有）上實測 `ViewThatFits` 對 `headerRow` 候選 1「放得下」的
/// 判定本來就是用兩顆鈕未換行的自然寬度比較（340–402pt 階梯掃描：候選 1/2 切換點在拿掉
/// `lineLimit(1)`／`fixedSize(horizontal:)` 前後是同一個值，全程沒有中間「候選 1 被選中但文字
/// 壓縮」的壓縮帶）——這兩支測試在這個 runtime 上 mutation **不會**轉紅，只提供「這兩個已知
/// 窄寬度下 Header 仍然單行或乾淨降級」的迴歸覆蓋（未來 padding／字級調整若讓自然寬度真的超出
/// 這兩個寬度，這裡會抓到）。修飾字本身「拒絕壓縮」的效果由下面
/// `testButtonCompressionProxy_refusesToWrapUnderExplicitNarrowFrame` 決定性驗證（繞開
/// `ViewThatFits`，mutation 會轉紅，見該測試文件註解）。
@MainActor
final class TimelineHeaderNarrowWidthUITests: XCTestCase {
    /// `ImportEntryButton`／`createMemoryButton` 的最小點擊區都是 `.frame(minHeight: 48)`
    /// （見兩者文件註解），單行文字視覺高度落在 30–40pt 之間。上限抓 60pt：遠高於任何單行 pill
    /// 的實際高度，又遠低於文字被壓成 4 行字（實機重現的直排壓縮）會撐到的高度（>100pt），中間
    /// 留足夠餘裕不誤判。
    private static let maxSingleLineHeight: CGFloat = 60

    func testHeader390pt_buttonsStayHorizontalSingleLine() {
        assertButtonsNotStacked(.timelineHeaderNarrow390)
    }

    func testHeader375pt_buttonsStayHorizontalSingleLine() {
        assertButtonsNotStacked(.timelineHeaderNarrow375)
    }

    /// 決定性 mutation 覆蓋：把 `ImportEntryButton` 的
    /// `.lineLimit(1).fixedSize(horizontal: true, vertical: false)` 拿掉重跑，這支測試會轉紅
    /// （2026-09-19 本機實測，`xcodebuild test` 原文——`TimelineView.createMemoryButton` 走的是
    /// 同一段 `Text` 修飾字寫法，不重複量測，見 `timelineButtonCompressionProxyHost` 文件註解）：
    /// ```
    /// XCTAssertGreaterThanOrEqual failed: ("59.0") is less than ("59.66666666666663") -
    /// TimelineViewButtonCompressionProxy：「匯入」鈕寬應 ≥ 高（被壓成直排橢圓，
    /// .frame(width: 60) 容器提案被照單全收換行壓縮）：
    /// frame=(165.66666666666666, 398.6666666666667, 59.0, 59.66666666666663)
    /// ```
    /// 機制見 `TapTargetGateHarness+Timeline.swift` 的 `timelineButtonCompressionProxyHost`
    /// 文件註解：`.frame(width: 60)` 是提案不是裁切，沒有 `fixedSize` 的 `Text` 照單全收換行
    /// 壓縮（鈕量測寬跌到接近容器寬、高度被撐到多行）；有 `fixedSize` 的 `Text` 無視提案回報
    /// 自然寬度，鈕整體溢出這個窄容器（量測寬遠大於容器、高度維持單行）。
    func testButtonCompressionProxy_refusesToWrapUnderExplicitNarrowFrame() {
        let screen = TapTargetGateScreenName.timelineButtonCompressionProxy
        let app = TapTargetMeasurement.launch(screen)
        TapTargetMeasurement.assertScreenRendered(screen, in: app)

        let importButton = app.buttons[QAAccessibilityID.timelineImportPhotos]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "\(screen.rawValue)：「匯入」鈕應該存在")
        let frame = importButton.frame
        XCTAssertGreaterThanOrEqual(
            frame.width, frame.height,
            "\(screen.rawValue)：「匯入」鈕寬應 ≥ 高（被壓成直排橢圓，" +
            ".frame(width: 60) 容器提案被照單全收換行壓縮）：frame=\(frame)"
        )
    }

    private func assertButtonsNotStacked(
        _ screen: TapTargetGateScreenName, file: StaticString = #filePath, line: UInt = #line
    ) {
        let app = TapTargetMeasurement.launch(screen)
        TapTargetMeasurement.assertScreenRendered(screen, in: app)

        let title = app.staticTexts["時間軸"].firstMatch
        let importButton = app.buttons[QAAccessibilityID.timelineImportPhotos]
        let createButton = app.buttons["新增回憶"]
        for element in [title, importButton, createButton] {
            XCTAssertTrue(
                element.waitForExistence(timeout: 10),
                "\(screen.rawValue)：標題與 Header 兩顆鈕都應該存在（標題不得被排法變化裁掉）",
                file: file, line: line
            )
        }

        for (label, element) in [("匯入", importButton), ("新增回憶", createButton)] {
            let frame = element.frame
            XCTAssertGreaterThanOrEqual(
                frame.width, frame.height,
                "\(screen.rawValue)：「\(label)」鈕寬應 ≥ 高（不是被壓成一字一行的直排橢圓）：" +
                "frame=\(frame)",
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                frame.height, Self.maxSingleLineHeight,
                "\(screen.rawValue)：「\(label)」鈕高 \(frame.height)pt 超過單行高度上限 " +
                "\(Self.maxSingleLineHeight)pt，文字可能被換行壓縮成多行",
                file: file, line: line
            )
        }

        assertNoOverlap([title, importButton, createButton], file: file, line: line)
    }
}

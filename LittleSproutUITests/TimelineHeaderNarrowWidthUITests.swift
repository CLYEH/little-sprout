import XCTest

/// LS-343（實機回報：iPhone 12 Pro 390pt，Header「新增回憶」被壓成一字一行、膠囊變成高瘦
/// 橢圓）——現有 tap-target gate（`TapTargetMeasurement.violations`）只驗最短邊 ≥44pt，換行
/// 壓縮成直排之後熱區反而「變高」，不會被那支既有檢查抓到（見該檔文件註解），這正是 LS-315 在
/// 402pt 機型驗收時漏網的原因。這裡額外驗「鈕寬 ≥ 鈕高」（不是被壓成直排的瘦長膠囊）與「高度
/// 落在單行範圍內」（換行成多行文字會把高度撐到遠超單行）。
///
/// **重現條件（merge-review R1 b975e587 重新量測訂正，R1 提交版誤判成「較舊 iOS runtime」）**：
/// 390pt／375pt ＋ Dynamic Type **`S`／`XS`（比預設 `L` 小一級）**——與 iOS 版本無關、與顯示
/// 縮放無關。機制：候選 1 的 `HStack` 在小字級下，按鈕群（右側內層 `HStack`）的可壓縮幅度會
/// 掉到比標題小，於是先分到「剩餘寬 ÷ 子項數」的窄提案、中文逐字換行，即使整列還空著一大段。
/// `M`／`L`／`XL` 不重現——`testHeader390pt_buttonsStayHorizontalSingleLine`／
/// `testHeader375pt_buttonsStayHorizontalSingleLine` 固定 `L` 字級，只提供這兩個寬度在預設
/// 字級下的迴歸覆蓋，不是 mutation-sensitive（拿掉修飾字這兩支仍綠，因為 `L` 字級本來就不觸發
/// 收縮順序反轉）；真正命中重現條件、mutation 決定性轉紅的是下面 `_small`／`_extraSmall` 兩組
/// 及 `testButtonCompressionProxy_refusesToWrapUnderExplicitNarrowFrame`（後者額外繞開
/// `ViewThatFits` 直接測修飾字本身，涵蓋範圍不重疊：`ViewThatFits` 候選 1/2 切換門檻本身確實
/// 不受這兩個修飾字影響，但候選 1 內部的收縮順序才是使用者實際踩到的那個 bug）。
@MainActor
final class TimelineHeaderNarrowWidthUITests: XCTestCase {
    /// `ImportEntryButton`／`createMemoryButton` 的最小點擊區都是 `.frame(minHeight: 48)`
    /// （見兩者文件註解），單行文字視覺高度落在 30–40pt 之間。上限抓 60pt：遠高於任何單行 pill
    /// 的實際高度，又遠低於文字被壓成多行字（重現的直排壓縮，S／XS 下量到 89–92pt）會撐到的
    /// 高度，中間留足夠餘裕不誤判。
    private static let maxSingleLineHeight: CGFloat = 60
    private static let small = "UICTContentSizeCategoryS"
    private static let extraSmall = "UICTContentSizeCategoryXS"

    func testHeader390pt_buttonsStayHorizontalSingleLine() {
        assertButtonsNotStacked(.timelineHeaderNarrow390)
    }

    func testHeader375pt_buttonsStayHorizontalSingleLine() {
        assertButtonsNotStacked(.timelineHeaderNarrow375)
    }

    /// 決定性 mutation 覆蓋（merge-review R1 M1）：390pt＋`S`——命中重現條件。把兩顆鈕的
    /// `lineLimit(1)`／`fixedSize(horizontal:)` 拿掉重跑，本機實測轉紅（原文）：
    /// ```
    /// XCTAssertGreaterThanOrEqual failed: ("69.66666666666669") is less than
    /// ("92.33333333333331") - TimelineViewHeaderNarrow390：「新增回憶」鈕寬應 ≥ 高（不是被壓成
    /// 一字一行的直排橢圓）：frame=(302.3333333333333, 70.0, 69.66666666666669, 92.33333333333331)
    /// ```
    /// 補回修飾字後轉綠。
    func testHeader390pt_smallSize_buttonsStayHorizontalSingleLine() {
        assertButtonsNotStacked(.timelineHeaderNarrow390, contentSizeCategory: Self.small)
    }

    /// 同上，390pt＋`XS`（比 `S` 再小一級，重現條件的另一端）。
    func testHeader390pt_extraSmallSize_buttonsStayHorizontalSingleLine() {
        assertButtonsNotStacked(.timelineHeaderNarrow390, contentSizeCategory: Self.extraSmall)
    }

    /// 同上，375pt＋`XS`（票文另一個實機寬度，同一重現條件）。
    func testHeader375pt_extraSmallSize_buttonsStayHorizontalSingleLine() {
        assertButtonsNotStacked(.timelineHeaderNarrow375, contentSizeCategory: Self.extraSmall)
    }

    /// 決定性 mutation 覆蓋（merge-review R1 m1：proxy 現在同時涵蓋兩顆鈕，見
    /// `TimelineView.debugHeaderButtonsForCompressionProxy` 文件註解）：把兩顆鈕的
    /// `.lineLimit(1).fixedSize(horizontal: true, vertical: false)` 拿掉重跑，這支測試會轉紅
    /// （2026-09-19 本機實測，`xcodebuild test` 原文）：
    /// ```
    /// XCTAssertGreaterThanOrEqual failed: ("59.0") is less than ("59.666666666666686") -
    /// TimelineViewButtonCompressionProxy：「匯入」鈕寬應 ≥ 高（被壓成直排橢圓，
    /// .frame(width: 60) 容器提案被照單全收換行壓縮）：
    /// frame=(171.66666666666666, 363.0, 59.0, 59.666666666666686)
    ///
    /// XCTAssertGreaterThanOrEqual failed: ("60.0") is less than ("100.33333333333331") -
    /// TimelineViewButtonCompressionProxy：「新增回憶」鈕寬應 ≥ 高（被壓成直排橢圓，
    /// .frame(width: 60) 容器提案被照單全收換行壓縮）：
    /// frame=(171.0, 438.6666666666667, 60.0, 100.33333333333331)
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
        let createButton = app.buttons["新增回憶"]
        for (label, element) in [("匯入", importButton), ("新增回憶", createButton)] {
            XCTAssertTrue(element.waitForExistence(timeout: 10), "\(screen.rawValue)：「\(label)」鈕應該存在")
            let frame = element.frame
            XCTAssertGreaterThanOrEqual(
                frame.width, frame.height,
                "\(screen.rawValue)：「\(label)」鈕寬應 ≥ 高（被壓成直排橢圓，" +
                ".frame(width: 60) 容器提案被照單全收換行壓縮）：frame=\(frame)"
            )
        }
    }

    private func assertButtonsNotStacked(
        _ screen: TapTargetGateScreenName, contentSizeCategory: String = "UICTContentSizeCategoryL",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let app = TapTargetMeasurement.launch(screen, contentSizeCategory: contentSizeCategory)
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

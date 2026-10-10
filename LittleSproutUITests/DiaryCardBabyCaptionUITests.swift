import XCTest

/// LS-374：時間軸日記卡寶貝署名（`MultiChildCaptionFormatter`，稿面 `cmp/Card Diary` `qtCd7`
/// 單寶貝 Name／Sep／Age、多寶貝 `x7k2o6`）截圖矩陣——一位／兩位／三位 × xSmall／預設 L／AX3 ×
/// 淺／深，截圖以 `LS-374-<fixture>-<size>-<scheme>` 附在 xcresult（`keepAlways`）。
///
/// 斷言念出來的字：日記卡 `.accessibilityElement(children: .combine)`，署名與正文合成卡片 label——
/// 每人都帶「·」（稿面「全稿一義」）、三位寶貝 AX3 不因截斷少念任何一個名字。逐字元（U+00A0／
/// U+2060）比對在單元測試 `MultiChildCaptionFormatterTests`；a11y label 會吞 U+2060。
///
/// LS-447（LS-442 C4a，稿 `kmbyt`／`YXnTc` 第一、四欄）：署名落款在內文下方靠右、前有 1pt 線；AX 字級
/// 多寶貝每人兩行。版面量測靠 `DiaryCardView.qaFrameHook`（DEBUG 透明疊層，卡片 `.combine` 後唯一量得到
/// 內文／線／署名各自 frame 的路徑）。座標斷言一律相對參照（線、內文、署名彼此的相對位置），不用絕對常數。
@MainActor
final class DiaryCardBabyCaptionUITests: XCTestCase {
    private static let sizes = [
        ("xSmall", "UICTContentSizeCategoryXS"),
        ("L", "UICTContentSizeCategoryL"),
        ("AX3", "UICTContentSizeCategoryAccessibilityXL")
    ]
    private static let schemes = ["light", "dark"]

    func testOneChild_matrix() {
        assertMatrix(fixture: "one", spokenCaption: "小安 · 2 歲 3 個月")
    }

    func testTwoChildren_matrix() {
        assertMatrix(fixture: "two", spokenCaption: "小安 · 2 歲 3 個月、小明 · 8 個月大")
    }

    func testThreeChildren_matrix() {
        assertMatrix(
            fixture: "three", spokenCaption: "歐陽彥廷 · 2 歲 3 個月、小饅頭 · 1 歲 8 個月、Emma Chen · 8 個月大"
        )
    }

    // MARK: - LS-447：署名落款位置

    /// 預設字級：署名在內文之下、線在兩者之間、署名靠右（右緣對齊線右緣＝卡片內容區右緣）、
    /// 互動列在署名之下；截圖對稿 `YXnTc` 第一欄（`LS-447-default-light`）。
    func testDefaultSize_signatureBelowBodyTrailingWithRule() {
        let app = launch(fixture: "two", size: "UICTContentSizeCategoryL", scheme: "light")
        let body = hook(app, "qa.diaryCard.body")
        let rule = hook(app, "qa.diaryCard.signOffRule")
        let signature = hook(app, "qa.diaryCard.signature")
        let likeToggle = app.buttons["qa.interactionRow.diary.likeToggle"].firstMatch
        for (name, element) in [("內文", body), ("分隔線", rule), ("署名", signature)] {
            XCTAssertTrue(element.waitForExistence(timeout: 10), "找不到\(name)量測掛勾")
        }
        XCTAssertTrue(likeToggle.exists, "找不到互動列愛心鈕")
        XCTAssertGreaterThanOrEqual(rule.frame.minY, body.frame.maxY, "分隔線應在內文之下")
        XCTAssertGreaterThanOrEqual(signature.frame.minY, rule.frame.maxY, "署名應在分隔線之下（落款，不在頂端）")
        XCTAssertGreaterThanOrEqual(likeToggle.frame.minY, signature.frame.maxY - 1, "互動列應在署名之下")
        XCTAssertLessThanOrEqual(rule.frame.height, 2, "分隔線是 1pt 細線，實際高 \(rule.frame.height)")
        XCTAssertEqual(
            signature.frame.maxX, rule.frame.maxX, accuracy: 2,
            "署名應靠右（右緣 \(signature.frame.maxX) 對齊線右緣 \(rule.frame.maxX)）"
        )
        XCTAssertGreaterThan(
            signature.frame.minX, rule.frame.minX + 8, "兩位寶貝署名不應撐滿整條線（靠右落款，左側留白）"
        )
        let gapAbove = rule.frame.minY - body.frame.maxY
        let gapBelow = signature.frame.minY - rule.frame.maxY
        XCTAssertEqual(gapBelow, 8, accuracy: 2, "線到署名應為 $sp-label 8pt，實際 \(gapBelow)")
        XCTAssertGreaterThanOrEqual(gapAbove, 8 - 2, "內文到線至少 $sp-label 8pt，實際 \(gapAbove)")
        attach(app, name: "LS-447-default-light")
        app.terminate()
    }

    /// AX3 兩位寶貝：四行（小安／· 2 歲 3 個月／小明／· 8 個月大），每行單行完整（高度與其他行同級＝沒再折行）、
    /// 全部靠右對齊線右緣、不超出線左緣；朗讀仍是一整串。截圖對稿 `YXnTc` 第四欄（`LS-447-AX3-light`）。
    func testAX3_twoChildren_fourLines_eachLineIntactTrailingAligned() {
        let app = launch(
            fixture: "two", size: "UICTContentSizeCategoryAccessibilityXL", scheme: "light"
        )
        let rule = hook(app, "qa.diaryCard.signOffRule")
        XCTAssertTrue(rule.waitForExistence(timeout: 10), "找不到分隔線量測掛勾")
        let lines = (0..<4).map { hook(app, "qa.diaryCard.signatureLine.\($0)") }
        for (index, line) in lines.enumerated() {
            XCTAssertTrue(line.exists, "AX3 兩位寶貝應有四行署名，第 \(index) 行不存在（沒走每人兩行分支？）")
        }
        XCTAssertFalse(hook(app, "qa.diaryCard.signatureLine.4").exists, "兩位寶貝只該有四行，不該有第五行")
        let heights = lines.map(\.frame.height)
        let singleLine = heights.min() ?? 0
        XCTAssertGreaterThan(singleLine, 0)
        for (index, line) in lines.enumerated() {
            XCTAssertLessThan(
                heights[index], singleLine * 1.5,
                "第 \(index) 行高 \(heights[index]) 超過單行 \(singleLine) 的 1.5 倍——折成兩行了，不是每行完整"
            )
            XCTAssertEqual(
                line.frame.maxX, rule.frame.maxX, accuracy: 2, "第 \(index) 行應靠右對齊線右緣（trailing）"
            )
            XCTAssertGreaterThanOrEqual(
                line.frame.minX, rule.frame.minX - 1, "第 \(index) 行不應超出卡片內容區左緣（被裁／溢出）"
            )
            XCTAssertGreaterThanOrEqual(line.frame.minY, rule.frame.maxY, "第 \(index) 行應在分隔線之下")
            if index > 0 {
                XCTAssertGreaterThanOrEqual(
                    line.frame.minY, lines[index - 1].frame.maxY - 1, "第 \(index) 行應排在第 \(index - 1) 行之下"
                )
            }
        }
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "溜滑梯")).firstMatch
        let spoken = card.label
            .replacingOccurrences(of: "\u{2060}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertTrue(spoken.contains("小安 · 2 歲 3 個月、小明 · 8 個月大"), "AX 分支朗讀應維持一整串，實際：\(spoken)")
        attach(app, name: "LS-447-AX3-light")
        app.terminate()
    }

    private func launch(fixture: String, size: String, scheme: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = "DiaryCardBabyCaption"
        app.launchEnvironment["LS_DIARY_CARD_CAPTION_FIXTURE"] = fixture
        app.launchEnvironment["LS_DIARY_CARD_CAPTION_SCHEME"] = scheme
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        app.launchWithRetry()
        return app
    }

    private func hook(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.otherElements[identifier].firstMatch
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertMatrix(
        fixture: String, spokenCaption: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        for (sizeName, size) in Self.sizes {
            for scheme in Self.schemes {
                let context = "\(fixture)-\(sizeName)-\(scheme)"
                let app = XCUIApplication()
                app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = "DiaryCardBabyCaption"
                app.launchEnvironment["LS_DIARY_CARD_CAPTION_FIXTURE"] = fixture
                app.launchEnvironment["LS_DIARY_CARD_CAPTION_SCHEME"] = scheme
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
                app.launchWithRetry()
                // 署名＋正文 `.combine` 成的那個元素（正文固定含「溜滑梯」）。
                let card = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", "溜滑梯")).firstMatch
                XCTAssertTrue(card.waitForExistence(timeout: 10), "[\(context)] 日記卡沒渲染", file: file, line: line)
                let spoken = card.label
                    .replacingOccurrences(of: "\u{2060}", with: "")
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                XCTAssertTrue(
                    spoken.contains(spokenCaption),
                    "[\(context)] 卡片應念出署名「\(spokenCaption)」，實際 label：\(spoken)", file: file, line: line
                )
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "LS-374-\(context)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }
}

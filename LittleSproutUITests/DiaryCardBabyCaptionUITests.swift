import XCTest

/// LS-374：時間軸日記卡寶貝署名（`MultiChildCaptionFormatter`，稿面 `cmp/Card Diary` `qtCd7`
/// 單寶貝 Name／Sep／Age、多寶貝 `x7k2o6`）截圖矩陣——一位／兩位／三位 × xSmall／預設 L／AX3 ×
/// 淺／深，截圖以 `LS-374-<fixture>-<size>-<scheme>` 附在 xcresult（`keepAlways`）。
///
/// 斷言念出來的字：日記卡 `.accessibilityElement(children: .combine)`，署名與正文合成卡片 label——
/// 每人都帶「·」（稿面「全稿一義」）、三位寶貝 AX3 不因截斷少念任何一個名字。逐字元（U+00A0／
/// U+2060）比對在單元測試 `MultiChildCaptionFormatterTests`；a11y label 會吞 U+2060。
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
                app.launch()
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

import XCTest

/// LS-166 票文範圍 4：相簿詳情 AX3（body 40pt）不破版——硬規則「可點元件 minHeight ≥48」與
/// 「Nav Row 兩顆按鈕（返回鍵／更多）在標題換行變長之後仍不重疊、可觸達」。AX 字級一律走
/// `launchArguments`（不用 `launchEnvironment`，同 `TapTargetMeasurement.launch(_:
/// contentSizeCategory:)` 既有理由，`LS-210` review 實測 `launchEnvironment` 對這個 app 無效）。
@MainActor
final class AlbumDetailAX3UITests: XCTestCase {
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    func testOwnerNavRowButtons_ax3_remainHittableAndDoNotOverlap() {
        let app = TapTargetMeasurement.launch(.albumDetailOwner, contentSizeCategory: Self.ax3)
        TapTargetMeasurement.assertScreenRendered(.albumDetailOwner, in: app)

        let backButton = app.buttons["相簿"].firstMatch
        let moreButton = app.buttons["更多操作"]
        let addPhotosButton = app.buttons["加入照片"]
        for element in [backButton, moreButton, addPhotosButton] {
            XCTAssertTrue(element.waitForExistence(timeout: 10), "AX3 下三顆可點元件都應該存在")
        }

        assertNoOverlap([backButton, moreButton])
        XCTAssertTrue(backButton.isHittable && moreButton.isHittable, "Nav Row 兩顆按鈕在 AX3 下都要可觸達")
    }

    /// 用 frame 交集判斷任兩個元素是否重疊——同 `ContentActionsAX3UITests.assertNoOverlap`
    /// 既有手法（`private`，跨檔案不可共用，這裡另寫一份最小版）。
    private func assertNoOverlap(_ elements: [XCUIElement], file: StaticString = #filePath, line: UInt = #line) {
        for firstIndex in 0..<elements.count {
            for secondIndex in (firstIndex + 1)..<elements.count {
                let first = elements[firstIndex]
                let second = elements[secondIndex]
                XCTAssertFalse(
                    first.frame.intersects(second.frame),
                    "AX3 下「\(first.label)」與「\(second.label)」不應該重疊：\(first.frame) vs \(second.frame)",
                    file: file, line: line
                )
            }
        }
    }
}

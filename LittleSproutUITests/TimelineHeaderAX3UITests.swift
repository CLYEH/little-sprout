import XCTest

/// LS-315 票文驗收：「AX3 三列不裁切」——`aGkJ1`（`A11y / 00 時間軸入口 · Dynamic Type AX3`）
/// 板要求 Header 在 AX3 改三列（Title／匯入／新增回憶，全帶文字），三顆元件都要可觸達、不
/// 重疊。同 `AlbumDetailAX3UITests` 既有手法（AX 字級一律走 `launchArguments`，見
/// `TapTargetMeasurement.launch(_:contentSizeCategory:)` 文件註解）。
@MainActor
final class TimelineHeaderAX3UITests: XCTestCase {
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    func testHeaderThreeRows_ax3_remainHittableAndDoNotOverlap() {
        let app = TapTargetMeasurement.launch(.timelineDefaultState, contentSizeCategory: Self.ax3)
        TapTargetMeasurement.assertScreenRendered(.timelineDefaultState, in: app)

        let title = app.staticTexts["時間軸"].firstMatch
        let importButton = app.buttons[QAAccessibilityID.timelineImportPhotos]
        let createButton = app.buttons["新增回憶"]
        for element in [title, importButton, createButton] {
            XCTAssertTrue(element.waitForExistence(timeout: 10), "AX3 下三列都應該存在（全帶文字）")
        }

        XCTAssertTrue(
            importButton.isHittable && createButton.isHittable, "AX3 下「匯入」／「新增回憶」都要可觸達"
        )
        assertNoOverlap([title, importButton, createButton])
    }
}

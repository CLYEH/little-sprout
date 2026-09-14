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

    /// 用 frame 交集判斷任兩個元素是否重疊——同 `Support/AssertNoOverlap.swift` 既有手法
    /// （LS-269，池 `3e9347c4` (4)：原註解指向已被搬走的 `ContentActionsAX3UITests
    /// .assertNoOverlap`，且「跨檔案不可共用」已被 LS-268 推翻）。**LS-272（池 `3d2b2ffe` (4)）**：
    /// 保留這份本體不同的私有版是測試意圖使然——這支測試要驗證的是 Nav Row 兩顆按鈕的 frame
    /// 在 AX3 下是否重疊，這個判斷不應該受「當下是不是 hittable」左右；共用版只比對
    /// `isHittable` 的元素是它自己的設計目的（捲動裁掉、不在畫面上的元素本來就不該納入判斷），
    /// 套用在這裡反而會篩掉本來就要測的情境，兩者服務不同的測試目的，因此不併入共用版
    /// （`private func` 會覆蓋同名全域函式，見該檔檔頭說明）。
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

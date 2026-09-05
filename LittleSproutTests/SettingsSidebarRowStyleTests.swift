import SwiftUI
import XCTest
@testable import LittleSprout

/// merge-review R3 M3：這條測試直接鎖住「選中列長什麼樣」，不透過渲染＋UITest 間接推論——
/// reviewer 實測 `SettingsViewIPadTests.testSidebarSelectionIsAccessibleAndDistinguishable`
/// 對「把 M2 視覺修法整個中性化」這種退化完全沒有鑑別力（四組 mutation 都測不出來，見
/// `SettingsView+Sidebar.swift` `sidebarRow` 文件註解）。這裡的 `testSelectedAndUnselected
/// StylesDiffer` 正是 reviewer 建議的「mutation b 會直接紅」那條純函式測試。
final class SettingsSidebarRowStyleTests: XCTestCase {
    func testSelectedAndUnselectedStylesDiffer() {
        XCTAssertNotEqual(
            SettingsSidebarRowStyle.style(isSelected: true),
            SettingsSidebarRowStyle.style(isSelected: false),
            "選中／未選中的樣式必須不同——這條測試在『把視覺修法整個中性化』的 mutation 下必須紅"
        )
    }

    func testSelectedStyleMatchesDesignTokens() {
        // 稿面 B2DckT 選中 Nav Item（KGKyg）：$print-paper 底＋$paper-edge 邊框＋
        // $paper-shadow 陰影＋粗體。
        let style = SettingsSidebarRowStyle.style(isSelected: true)
        XCTAssertEqual(style.background, .lsPrintPaper)
        XCTAssertEqual(style.borderColor, .lsPaperEdge)
        XCTAssertEqual(style.shadowColor, .lsPaperShadow)
        XCTAssertEqual(style.fontWeight, .bold)
    }

    func testUnselectedStyleHasNoBackgroundBorderOrShadow() {
        // 稿面 B2DckT 未選中 Nav Item（oO6z7）：全透明、一般粗細（600／semibold）。
        let style = SettingsSidebarRowStyle.style(isSelected: false)
        XCTAssertEqual(style.background, .clear)
        XCTAssertEqual(style.borderColor, .clear)
        XCTAssertEqual(style.shadowColor, .clear)
        XCTAssertEqual(style.fontWeight, .semibold)
    }
}

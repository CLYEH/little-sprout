import SwiftUI
@testable import LittleSprout
import XCTest

/// `ChildFilterLayout`：寶貝切換器分段／下拉的寬度判斷（LS-67 R3 F9 定案：寬度判斷，不是
/// 數量判斷）。以 `design/littlesprout.pen` `Stress/10 · 3 個寶貝＋超長名字` 壓測板為基準——
/// 3 位真實長名字（陳彥廷／小饅頭／Emma Chen）在 iPhone 標準寬度下會擠爆分段控制。
final class ChildFilterLayoutTests: XCTestCase {
    /// iPhone 標準內容寬度：393（螢幕寬）－ 24×2（`$screen-pad`）＝ 345。
    private let standardAvailableWidth: CGFloat = 345

    func test_forcesDropdown_belowAX3_isFalse() {
        XCTAssertFalse(ChildFilterLayout.forcesDropdown(dynamicTypeSize: .accessibility2))
        XCTAssertFalse(ChildFilterLayout.forcesDropdown(dynamicTypeSize: .large))
    }

    func test_forcesDropdown_ax3AndAbove_isTrue() {
        XCTAssertTrue(ChildFilterLayout.forcesDropdown(dynamicTypeSize: .accessibility3))
        XCTAssertTrue(ChildFilterLayout.forcesDropdown(dynamicTypeSize: .accessibility5))
    }

    func test_shouldUseDropdown_ax3_forcedRegardlessOfWidth() {
        // 就算只有 1 個寶貝、可用寬度很大，AX3 仍一律強制下拉。
        let result = ChildFilterLayout.shouldUseDropdown(
            childNames: ["小安"],
            availableWidth: 2000,
            dynamicTypeSize: .accessibility3
        )

        XCTAssertTrue(result)
    }

    func test_shouldUseDropdown_zeroOrOneChild_staysSegmented() {
        XCTAssertFalse(ChildFilterLayout.shouldUseDropdown(
            childNames: [],
            availableWidth: standardAvailableWidth,
            dynamicTypeSize: .large
        ))
        XCTAssertFalse(ChildFilterLayout.shouldUseDropdown(
            childNames: ["小安"],
            availableWidth: standardAvailableWidth,
            dynamicTypeSize: .large
        ))
    }

    func test_shouldUseDropdown_twoShortNames_fitsSegmented() {
        // 稿面主狀態：全部／小安／小軒，三個 segment 在標準寬度下不換行（R1 · 10 本稿）。
        let result = ChildFilterLayout.shouldUseDropdown(
            childNames: ["小安", "小軒"],
            availableWidth: standardAvailableWidth,
            dynamicTypeSize: .large
        )

        XCTAssertFalse(result)
    }

    func test_shouldUseDropdown_stressBoardThreeLongNames_overflowsToDropdown() {
        // Stress/10 壓測板：陳彥廷／小饅頭／Emma Chen 三個真實長名字會把分段控制擠爆
        // （LS-67 R3 F9：真控件 113pt/段，(345−6)/113≈3，第 3 個寶貝起改下拉）。
        let result = ChildFilterLayout.shouldUseDropdown(
            childNames: ["陳彥廷", "小饅頭", "Emma Chen"],
            availableWidth: standardAvailableWidth,
            dynamicTypeSize: .large
        )

        XCTAssertTrue(result)
    }

    func test_requiredWidth_scalesWithDynamicType() {
        let defaultWidth = ChildFilterLayout.requiredWidth(childNames: ["小安"], dynamicTypeSize: .large)
        let largerWidth = ChildFilterLayout.requiredWidth(childNames: ["小安"], dynamicTypeSize: .accessibility2)

        XCTAssertGreaterThan(largerWidth, defaultWidth)
    }

    func test_shouldUseDropdown_zeroAvailableWidth_defaultsToSegmented() {
        // 版面尚未量測完成（GeometryReader 第一次回報前）時的保守預設——不要一開始就跳下拉
        // 再閃回分段，寧可先假設分段，等真的測到寬度不夠再切換。
        let result = ChildFilterLayout.shouldUseDropdown(
            childNames: ["陳彥廷", "小饅頭", "Emma Chen"],
            availableWidth: 0,
            dynamicTypeSize: .large
        )

        XCTAssertFalse(result)
    }
}

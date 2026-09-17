import Foundation
@testable import LittleSprout
import XCTest

/// `GrowthEmptyStateCopy`／`TextWrapGuarantee`：04 空狀態 AX3 文案「末行 ≥3 字元、無孤字」
/// 機械保證（Notes `h5BNyi`→`TZOSC`，LS-312 驗收條件第三項）。
final class GrowthEmptyStateCopyTests: XCTestCase {
    /// 範圍內示範資料集兩個孩子名字（陳小安／陳小軒，皆 3 字）——逐字對齊 Notes 舉例
    /// （每行 4 字時末行「曲線。」＝3 字元）。
    func test_bodyText_demoChildNames_lastLineHasNoOrphan() {
        for name in ["陳小安", "陳小軒"] {
            let text = GrowthEmptyStateCopy.body(childName: name)

            let charsPerLine = GrowthEmptyStateCopy.ax3CharactersPerLine
            XCTAssertTrue(
                TextWrapGuarantee.lastLineHasNoOrphan(text, charactersPerLine: charsPerLine),
                "\(name) 的末行不應該是孤字：\(text)"
            )
        }
    }

    /// Notes 自己也承認 2 字孩子名字（例：「陳一」）在固定 4 字／行的框寬下會退化成 2 字孤字
    /// （`TZOSC`「對任意孩子名字都不可能穩定成立」）——釘住這個已知落差，不是漏測，未來若換了
    /// 折寬或句式，這支測試要嘛跟著變綠、要嘛提醒我們這個已知限制還在。
    func test_bodyText_twoCharacterChildName_isKnownOrphanCase() {
        let text = GrowthEmptyStateCopy.body(childName: "陳一")

        XCTAssertFalse(
            TextWrapGuarantee.lastLineHasNoOrphan(text, charactersPerLine: GrowthEmptyStateCopy.ax3CharactersPerLine)
        )
    }
}

/// `TextWrapGuarantee` 本身的行為——獨立於任何成長文案內容。
final class TextWrapGuaranteeTests: XCTestCase {
    func test_wrappedLineLengths_evenlyDivisible_allFullLines() {
        XCTAssertEqual(TextWrapGuarantee.wrappedLineLengths("12345678", charactersPerLine: 4), [4, 4])
    }

    func test_wrappedLineLengths_remainder_lastLineShorter() {
        XCTAssertEqual(TextWrapGuarantee.wrappedLineLengths("123456789", charactersPerLine: 4), [4, 4, 1])
    }

    func test_lastLineHasNoOrphan_belowMinimum_returnsFalse() {
        XCTAssertFalse(TextWrapGuarantee.lastLineHasNoOrphan("123456789", charactersPerLine: 4))
    }

    func test_lastLineHasNoOrphan_atOrAboveMinimum_returnsTrue() {
        XCTAssertTrue(TextWrapGuarantee.lastLineHasNoOrphan("123456781234567", charactersPerLine: 4))
    }

    func test_lastLineHasNoOrphan_emptyText_returnsTrue() {
        XCTAssertTrue(TextWrapGuarantee.lastLineHasNoOrphan("", charactersPerLine: 4))
    }
}

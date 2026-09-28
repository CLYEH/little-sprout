import SwiftUI
@testable import LittleSprout
import XCTest

/// 日記卡署名（`cmp/Card Diary` `qtCd7`，LS-374 對稿）：字串逐字對稿面（含 U+0020／U+00A0／
/// U+2060 的位置）、字級 `$fs-note`（＝`.body`，年齡不再降一階）、顏色角色（姓名主墨 600；單寶貝
/// 「 · 年齡」次墨 regular；多寶貝整串主墨 600）。
///
/// 為什麼逐字比：「·」前是可斷 U+0020、後是不斷 U+00A0，AX3 折行時「·」才會領銜下一行、不會
/// 孤懸行尾（LS-201 核可稿）；肉眼看不出兩種空白的差別，只有逐字斷言守得住。
final class MultiChildCaptionFormatterTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let asOf = BirthdayFormat.date(fromWireString: "2026-09-02")!

    private func child(_ name: String, born: String) -> Child {
        Child(
            id: UUID(), name: name, birthday: BirthdayFormat.date(fromWireString: born)!,
            avatarURL: nil, deletedAt: nil, createdAt: Date()
        )
    }

    private func caption(_ children: [Child]) -> AttributedString {
        MultiChildCaptionFormatter.attributed(children: children, asOf: asOf, timeZone: utc)
    }

    // MARK: - 字串逐字對稿

    /// 稿面 Name「小安」＋Sep「 · 」＋Age「2 歲 3 個⁠月」（`d41MUZ`／`WmQcz`／`zk1yE`）；
    /// SwiftUI 單一 Text 的斷行字元依 LS-119 Notes `ca7bA`：姓名＋U+0020＋「·」＋U+00A0＋年齡。
    func test_singleChild_matchesDesignExactly_dotLeadsWrap() {
        let text = String(caption([child("小安", born: "2024-06-02")]).characters)
        XCTAssertEqual(text, "小安 ·\u{00A0}2\u{00A0}歲\u{00A0}3\u{00A0}個\u{2060}月")
    }

    /// 稿面 `x7k2o6`：「小安 ·⎵2⎵歲⎵3⎵個⁠月、小明 ·⎵8⎵個⁠月」——每人都帶「·」、「、」分人。
    /// 未滿一歲的年齡片語 `BirthdayFormat.ageDescription` 固定帶「大」（「8 個⁠月⁠大」，照片卡／
    /// 相簿卡同一份輸出，LS-365），稿面範例字串省略「大」，其餘逐字相同。
    func test_twoChildren_matchesDesignMultiCaptionExactly() {
        let text = String(caption([child("小安", born: "2024-06-02"), child("小明", born: "2026-01-02")]).characters)
        XCTAssertEqual(
            text,
            "小安 ·\u{00A0}2\u{00A0}歲\u{00A0}3\u{00A0}個\u{2060}月"
                + "、小明 ·\u{00A0}8\u{00A0}個\u{2060}月\u{2060}大"
        )
    }

    /// 三位寶貝、年齡三種形狀（整歲／歲＋月／未滿一歲）——每個「·」前 U+0020、後 U+00A0。
    func test_threeChildren_everyPersonHasDotWithBreakableSpaceBeforeAndNBSPAfter() {
        let text = String(caption([
            child("陳彥廷", born: "2023-09-02"), child("小饅頭", born: "2025-01-02"),
            child("Emma Chen", born: "2026-01-02")
        ]).characters)
        XCTAssertEqual(
            text,
            "陳彥廷 ·\u{00A0}3\u{00A0}歲"
                + "、小饅頭 ·\u{00A0}1\u{00A0}歲\u{00A0}8\u{00A0}個\u{2060}月"
                + "、Emma Chen ·\u{00A0}8\u{00A0}個\u{2060}月\u{2060}大"
        )
        XCTAssertFalse(text.contains("\n"), "稿面 AX3（HLXo3 `kmbyt`）也是「、」串接自然折行，不是一行一人")
    }

    // MARK: - 字級／顏色

    /// 稿面 Name 600 `$print-ink`、Sep＋Age regular `$print-ink-secondary`，三者皆 `$fs-note`
    /// （17／AX3 40＝`.body`）——年齡不再是 `.footnote`（13pt）。
    func test_singleChild_nameSemiboldPrimary_dotAndAgeBodyRegularSecondary() {
        let attributed = caption([child("小安", born: "2024-06-02")])
        let runs = attributed.runs.map { (String(attributed[$0.range].characters), $0.font, $0.foregroundColor) }
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].0, "小安")
        XCTAssertEqual(runs[0].1, .body.weight(.semibold))
        XCTAssertEqual(runs[0].2, Color.lsTextPrimary)
        XCTAssertEqual(runs[1].0, " ·\u{00A0}2\u{00A0}歲\u{00A0}3\u{00A0}個\u{2060}月")
        XCTAssertEqual(runs[1].1, .body, "年齡字級應為 $fs-note（＝.body 17pt），不是降一階的 .footnote")
        XCTAssertEqual(runs[1].2, Color.lsTextSecondary)
    }

    /// 稿面 `x7k2o6` 是單一 text 節點：整串 600 `$print-ink` `$fs-note`——年齡與姓名同字級同色。
    func test_multipleChildren_wholeStringIsOneSemiboldPrimaryBodyRun() {
        let attributed = caption([child("小安", born: "2024-06-02"), child("小明", born: "2026-01-02")])
        let runs = Array(attributed.runs)
        XCTAssertEqual(runs.count, 1, "多寶貝應為單一 run（稿面單一 text 節點），實際 \(runs.count) 段")
        XCTAssertEqual(runs.first?.font, .body.weight(.semibold))
        XCTAssertEqual(runs.first?.foregroundColor, Color.lsTextPrimary)
    }
}

import SwiftUI
@testable import LittleSprout
import XCTest

final class MultiChildCaptionFormatterTests: XCTestCase {
    private func child(name: String, birthday: Date) -> Child {
        Child(id: UUID(), name: name, birthday: birthday, avatarURL: nil, deletedAt: nil, createdAt: Date())
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ isoString: String) -> Date {
        BirthdayFormat.date(fromWireString: isoString)!
    }

    // MARK: - 單寶貝：「姓名 · 年齡」／多寶貝：「姓名 年齡、姓名 年齡」（頓號分人，不用「·」）
    //
    // LS-130 順手項（dead-code-sweeper，comment f696170c）：這三條原本斷言
    // `MultiChildCaptionFormatter.plainText(...)`（純文字版）的輸出，但 `plainText` 在生產
    // 程式碼裡沒有任何呼叫端——`DiaryCardView`／`DiaryDetailView` 都用
    // `.accessibilityElement(children: .combine)`，VoiceOver 直接讀 `attributed(...)` 產出的
    // `Text` 內容，不需要另一份純文字字串。已刪除 `plainText`；格式規則（單寶貝 `·`、多寶貝
    // `、`、不斷行空格）改斷言在實際使用的 `attributed(...)` 輸出上，不流失原本的測試意圖。

    func test_attributed_singleChild_usesMiddleDotFormat() {
        let anan = child(name: "陳小安", birthday: date("2024-06-02"))
        let attributed = MultiChildCaptionFormatter.attributed(
            children: [anan], asOf: date("2026-09-02"), calendar: utcCalendar
        )
        // 2024-06-02 → 2026-09-02：2 歲 3 個月。
        XCTAssertEqual(String(attributed.characters), "陳小安 · 2\u{00A0}歲\u{00A0}3\u{00A0}個月")
    }

    func test_attributed_multipleChildren_usesCommaFormatWithoutMiddleDot() {
        let anan = child(name: "陳小安", birthday: date("2024-06-02"))
        let xuan = child(name: "陳小軒", birthday: date("2020-01-15"))
        let attributed = MultiChildCaptionFormatter.attributed(
            children: [anan, xuan], asOf: date("2026-09-02"), calendar: utcCalendar
        )
        let text = String(attributed.characters)
        XCTAssertFalse(text.contains("·"), "多寶貝格式不用「·」")
        XCTAssertTrue(text.contains("、"), "多寶貝格式用頓號分人")
        XCTAssertEqual(
            text, "陳小安 2\u{00A0}歲\u{00A0}3\u{00A0}個月、陳小軒 6\u{00A0}歲\u{00A0}7\u{00A0}個月"
        )
    }

    func test_attributed_youngChild_monthsOnlyForm() {
        let baby = child(name: "小寶", birthday: date("2026-05-02"))
        let attributed = MultiChildCaptionFormatter.attributed(
            children: [baby], asOf: date("2026-09-02"), calendar: utcCalendar
        )
        XCTAssertEqual(String(attributed.characters), "小寶 · 4\u{00A0}個月大")
    }

    // MARK: - 不斷行空格：數字與單位間一律 NBSP，不用一般空格

    func test_segments_age_hasNoRegularSpace() {
        let anan = child(name: "陳小安", birthday: date("2024-06-02"))
        let segments = MultiChildCaptionFormatter.segments(
            children: [anan], asOf: date("2026-09-02"), calendar: utcCalendar
        )
        XCTAssertEqual(segments.count, 1)
        XCTAssertFalse(segments[0].age.contains(" "), "年齡段不應含一般空格（避免斷行拆開數字與單位）")
        XCTAssertTrue(segments[0].age.contains("\u{00A0}"), "年齡段的數字與單位間應為不斷行空格")
    }

    // MARK: - 年齡段降一階：姓名與年齡使用不同字級／顏色的 run

    func test_attributed_ageRun_usesDownsteppedFontAndSecondaryColor() {
        let anan = child(name: "陳小安", birthday: date("2024-06-02"))
        let attributed = MultiChildCaptionFormatter.attributed(
            children: [anan], asOf: date("2026-09-02"), calendar: utcCalendar
        )
        let plain = String(attributed.characters)
        XCTAssertTrue(plain.contains("陳小安"))
        XCTAssertTrue(plain.contains("2\u{00A0}歲\u{00A0}3\u{00A0}個月"))

        var sawNameRun = false
        var sawAgeRun = false
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            if text == "陳小安" {
                sawNameRun = true
                XCTAssertEqual(run.font, .body.weight(.semibold))
                XCTAssertEqual(run.foregroundColor, Color.lsTextPrimary)
            }
            if text.contains("個月") {
                sawAgeRun = true
                XCTAssertEqual(run.font, .footnote, "年齡段字級應比姓名（.body）降一階")
                XCTAssertEqual(run.foregroundColor, Color.lsTextSecondary)
            }
        }
        XCTAssertTrue(sawNameRun)
        XCTAssertTrue(sawAgeRun)
    }
}

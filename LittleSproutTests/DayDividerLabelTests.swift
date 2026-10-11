import XCTest
@testable import LittleSprout

/// LS-464（LS-454 C3a）：AX 字級日期章在「日期本體」與「附註」之間明確斷兩行（規則卡 `lvdD5` `i1Jn6`）；
/// 只有本體（今天／昨天）一行；非 AX 字級輸出不變。
final class DayDividerLabelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }

    private func day(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    func test_label_axBreaksBetweenDateAndWeekday_otherwiseOneLine() {
        let now = day(9, 14)
        let date = day(9, 10)
        XCTAssertEqual(DayDividerView.label(for: date, now: now, calendar: calendar, twoLines: true), "9月10日\n星期四")
        XCTAssertEqual(DayDividerView.label(for: date, now: now, calendar: calendar, twoLines: false), "9月10日 星期四")
    }

    func test_label_bodyOnly_isOneLineInBothLayouts() {
        let now = day(9, 14)
        for twoLines in [true, false] {
            XCTAssertEqual(DayDividerView.label(for: now, now: now, calendar: calendar, twoLines: twoLines), "今天")
            let yesterday = day(9, 13)
            XCTAssertEqual(DayDividerView.label(for: yesterday, now: now, calendar: calendar, twoLines: twoLines), "昨天")
        }
    }
}

import Foundation
@testable import LittleSprout
import XCTest

final class DiaryDateFormatTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let locale = Locale(identifier: "zh_Hant_TW")

    func test_today_appendsTodaySuffix() {
        let now = Date()
        XCTAssertTrue(
            DiaryDateFormat.displayString(for: now, now: now, calendar: calendar, locale: locale).hasSuffix("（今天）")
        )
    }

    func test_pastDate_noTodaySuffix() {
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let result = DiaryDateFormat.displayString(for: yesterday, now: now, calendar: calendar, locale: locale)
        XCTAssertFalse(result.contains("今天"))
    }

    func test_formatsAsMonthDay() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 31
        let date = calendar.date(from: components)!
        let farFuture = calendar.date(byAdding: .year, value: 5, to: date)!

        let result = DiaryDateFormat.displayString(for: date, now: farFuture, calendar: calendar, locale: locale)

        XCTAssertEqual(result, "8月31日")
    }
}

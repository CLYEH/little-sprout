import Foundation
@testable import LittleSprout
import XCTest

/// Owner 審核清單每筆申請的送出時間顯示——見 `JoinRequestTimeFormatter` 文件註解。
final class JoinRequestTimeFormatterTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func makeDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    func test_sameDay_lessThanOneMinute_isJustNow() {
        let now = makeDate(2026, 8, 24, 10, 0)
        let date = makeDate(2026, 8, 24, 9, 59, 40)

        XCTAssertEqual(JoinRequestTimeFormatter.format(date, now: now, calendar: calendar), "剛剛")
    }

    func test_sameDay_minutesAgo_showsMinutes() {
        let now = makeDate(2026, 8, 24, 10, 0)
        let date = makeDate(2026, 8, 24, 9, 58)

        XCTAssertEqual(JoinRequestTimeFormatter.format(date, now: now, calendar: calendar), "2 分鐘前")
    }

    func test_sameDay_hoursAgo_showsHours() {
        let now = makeDate(2026, 8, 24, 10, 0)
        let date = makeDate(2026, 8, 24, 7, 0)

        XCTAssertEqual(JoinRequestTimeFormatter.format(date, now: now, calendar: calendar), "3 小時前")
    }

    func test_yesterday_showsYesterdayPrefix() {
        let now = makeDate(2026, 8, 24, 10, 0)
        let date = makeDate(2026, 8, 23, 20, 14)

        XCTAssertEqual(JoinRequestTimeFormatter.format(date, now: now, calendar: calendar), "昨天 20:14")
    }

    func test_olderDate_showsMonthDay() {
        let now = makeDate(2026, 8, 24, 10, 0)
        let date = makeDate(2026, 8, 20, 20, 14)

        XCTAssertEqual(JoinRequestTimeFormatter.format(date, now: now, calendar: calendar), "8/20 20:14")
    }
}

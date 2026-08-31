import Foundation
@testable import LittleSprout
import XCTest

/// `BirthdayFormat`：`children.birthday`（Postgres `date`，無時區）與 `DatePicker`（裝置本地
/// 時區的 `Date`）之間的轉換——核心風險是「使用者在非 UTC 時區選的日期，編碼／解碼一來一回
/// 位移成前一天或後一天」，見該檔文件註解。
final class BirthdayFormatTests: XCTestCase {
    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func localCalendar(timeZoneIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar
    }

    func test_wireString_utcCalendar_formatsAsPlainDate() {
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 12
        let date = utcCalendar().date(from: components)!

        XCTAssertEqual(BirthdayFormat.wireString(from: date, calendar: utcCalendar()), "2024-03-12")
    }

    /// UTC+13（例如 Auckland 夏令時）選「3 月 12 日 00:00 local」——換成 UTC 是「3 月 11 日
    /// 11:00」。若照 SDK 預設編碼（一律轉 UTC 再取日期）會誤存成 3 月 11 日；`wireString`
    /// 用 `calendar`（呼叫端傳入的 local calendar）抽年月日，必須仍然是 3 月 12 日。
    func test_wireString_positiveOffsetTimeZone_keepsPickedCalendarDay() {
        let localCal = localCalendar(timeZoneIdentifier: "Pacific/Auckland")
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 12
        components.hour = 0
        components.timeZone = localCal.timeZone
        let pickedDate = localCal.date(from: components)!

        XCTAssertEqual(BirthdayFormat.wireString(from: pickedDate, calendar: localCal), "2024-03-12")
    }

    /// UTC-11（Pago Pago）選「3 月 12 日 00:00 local」——換成 UTC 是「3 月 12 日 11:00」，
    /// 同樣要保留使用者實際選的日曆日，不因時區偏移而跑掉。
    func test_wireString_negativeOffsetTimeZone_keepsPickedCalendarDay() {
        let localCal = localCalendar(timeZoneIdentifier: "Pacific/Pago_Pago")
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 12
        components.hour = 0
        components.timeZone = localCal.timeZone
        let pickedDate = localCal.date(from: components)!

        XCTAssertEqual(BirthdayFormat.wireString(from: pickedDate, calendar: localCal), "2024-03-12")
    }

    func test_dateFromWireString_roundTripsWireString() {
        let date = BirthdayFormat.date(fromWireString: "2024-03-12")

        XCTAssertNotNil(date)
        XCTAssertEqual(BirthdayFormat.wireString(from: date!, calendar: utcCalendar()), "2024-03-12")
    }

    func test_dateFromWireString_invalidString_returnsNil() {
        XCTAssertNil(BirthdayFormat.date(fromWireString: "not-a-date"))
    }

    func test_displayString_formatsTraditionalChinese() {
        let date = BirthdayFormat.date(fromWireString: "2024-03-12")!

        XCTAssertEqual(BirthdayFormat.displayString(from: date), "2024年3月12日")
    }

    // MARK: - ageDescription

    func test_ageDescription_wholeYearsNoExtraMonths_omitsMonths() {
        let birthday = BirthdayFormat.date(fromWireString: "2022-03-12")!
        let now = BirthdayFormat.date(fromWireString: "2024-03-12")!

        XCTAssertEqual(BirthdayFormat.ageDescription(birthday: birthday, now: now, calendar: utcCalendar()), "2 歲")
    }

    func test_ageDescription_yearsAndMonths_includesBoth() {
        let birthday = BirthdayFormat.date(fromWireString: "2022-01-01")!
        let now = BirthdayFormat.date(fromWireString: "2024-04-15")!

        XCTAssertEqual(BirthdayFormat.ageDescription(birthday: birthday, now: now, calendar: utcCalendar()), "2 歲 3 個月")
    }

    func test_ageDescription_underOneYear_usesMonthsOnlyPhrasing() {
        let birthday = BirthdayFormat.date(fromWireString: "2023-09-12")!
        let now = BirthdayFormat.date(fromWireString: "2024-03-12")!

        XCTAssertEqual(BirthdayFormat.ageDescription(birthday: birthday, now: now, calendar: utcCalendar()), "6 個月大")
    }

    /// `now` 用「使用者現在的今天」（呼叫端 local calendar 抽出的年月日）而不是 `Date()` 的
    /// 原始 UTC 瞬間——不然在 UTC+13 剛過午夜的使用者，用 UTC 瞬間算出來的「今天」還是前一天，
    /// 生日當天算出來的年齡會少一天可能造成月份少算。
    func test_ageDescription_usesCallerLocalCalendarForToday() {
        let localCal = localCalendar(timeZoneIdentifier: "Pacific/Auckland")
        var nowComponents = DateComponents()
        nowComponents.year = 2024
        nowComponents.month = 3
        nowComponents.day = 12
        nowComponents.hour = 0
        nowComponents.minute = 30
        nowComponents.timeZone = localCal.timeZone
        let nowLocal = localCal.date(from: nowComponents)!
        let birthday = BirthdayFormat.date(fromWireString: "2022-03-12")!

        XCTAssertEqual(BirthdayFormat.ageDescription(birthday: birthday, now: nowLocal, calendar: localCal), "2 歲")
    }
}

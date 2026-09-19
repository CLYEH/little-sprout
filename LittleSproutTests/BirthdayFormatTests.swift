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

    /// LS-331：裝置曆法設成非西曆（民國曆／佛曆／和曆）時建構「同一個絕對時間點」用的曆法，
    /// 只用來組出 `pickedDate`（模擬那個曆法下的 `DatePicker` 實際會產生的 `Date`），不是
    /// `wireString` 的輸入參數——新簽名只吃 `timeZone`，曆法識別碼不會流進 `wireString`。
    private func nonGregorianCalendar(_ identifier: Calendar.Identifier, timeZoneIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar
    }

    func test_wireString_utcCalendar_formatsAsPlainDate() {
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 12
        let date = utcCalendar().date(from: components)!

        XCTAssertEqual(BirthdayFormat.wireString(from: date, timeZone: utcCalendar().timeZone), "2024-03-12")
    }

    /// UTC+13（例如 Auckland 夏令時）選「3 月 12 日 00:00 local」——換成 UTC 是「3 月 11 日
    /// 11:00」。若照 SDK 預設編碼（一律轉 UTC 再取日期）會誤存成 3 月 11 日；`wireString`
    /// 用注入的 `timeZone` 抽年月日，必須仍然是 3 月 12 日。
    func test_wireString_positiveOffsetTimeZone_keepsPickedCalendarDay() {
        let localCal = localCalendar(timeZoneIdentifier: "Pacific/Auckland")
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 12
        components.hour = 0
        components.timeZone = localCal.timeZone
        let pickedDate = localCal.date(from: components)!

        XCTAssertEqual(BirthdayFormat.wireString(from: pickedDate, timeZone: localCal.timeZone), "2024-03-12")
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

        XCTAssertEqual(BirthdayFormat.wireString(from: pickedDate, timeZone: localCal.timeZone), "2024-03-12")
    }

    func test_dateFromWireString_roundTripsWireString() {
        let date = BirthdayFormat.date(fromWireString: "2024-03-12")

        XCTAssertNotNil(date)
        XCTAssertEqual(BirthdayFormat.wireString(from: date!, timeZone: utcCalendar().timeZone), "2024-03-12")
    }

    // MARK: - LS-331：裝置曆法非西曆（民國曆／佛曆／和曆）

    /// 根因：`Calendar(identifier: .republicOfChina)` 對「2026-09-19（西元）」抽出的
    /// `.year` 元件是 `115`（民國年＝西元年−1911）——若 `wireString` 直接拿裝置曆法的年月日
    /// 組字串，DB 就會存進 `"0115-09-19"`。這裡先用民國曆／西曆互相 round-trip 證明
    /// `pickedDate` 只是一個跟曆法無關的絕對時間點（`DatePicker` 在民國曆裝置上選「115 年
    /// 9 月 19 日」得到的就是這個時間點），再驗證 `wireString` 抽出來的必須是西元年
    /// `"2026-09-19"`，不是 `"0115-09-19"`——年份錯了，孩子年齡、時間軸排序、成長曲線
    /// 全部跟著錯。
    func test_wireString_republicOfChinaCalendarDate_returnsGregorianWireString() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Taipei"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let referenceDate = try XCTUnwrap(gregorian.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 10)))

        let roc = nonGregorianCalendar(.republicOfChina, timeZoneIdentifier: "Asia/Taipei")
        let rocComponents = roc.dateComponents([.era, .year, .month, .day, .hour], from: referenceDate)
        XCTAssertEqual(rocComponents.year, 115, "民國曆年份元件應為西元年−1911——證明 bug 場景是真的")
        let pickedDate = try XCTUnwrap(roc.date(from: rocComponents))
        XCTAssertEqual(pickedDate, referenceDate, "民國曆重建應與西曆原始時間點是同一個絕對時間")

        XCTAssertEqual(BirthdayFormat.wireString(from: pickedDate, timeZone: timeZone), "2026-09-19")
    }

    /// 同上，佛曆（泰國）：`.year` 元件是西元年+543。
    func test_wireString_buddhistCalendarDate_returnsGregorianWireString() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Taipei"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let referenceDate = try XCTUnwrap(gregorian.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 10)))

        let buddhist = nonGregorianCalendar(.buddhist, timeZoneIdentifier: "Asia/Taipei")
        let buddhistComponents = buddhist.dateComponents([.era, .year, .month, .day, .hour], from: referenceDate)
        XCTAssertEqual(buddhistComponents.year, 2569, "佛曆年份元件應為西元年+543——證明 bug 場景是真的")
        let pickedDate = try XCTUnwrap(buddhist.date(from: buddhistComponents))
        XCTAssertEqual(pickedDate, referenceDate, "佛曆重建應與西曆原始時間點是同一個絕對時間")

        XCTAssertEqual(BirthdayFormat.wireString(from: pickedDate, timeZone: timeZone), "2026-09-19")
    }

    /// 同上，和曆（令和）：`.year` 元件是令和年號（西元 2026 年是令和 8 年）。
    func test_wireString_japaneseCalendarDate_returnsGregorianWireString() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Taipei"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let referenceDate = try XCTUnwrap(gregorian.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 10)))

        let japanese = nonGregorianCalendar(.japanese, timeZoneIdentifier: "Asia/Taipei")
        let japaneseComponents = japanese.dateComponents([.era, .year, .month, .day, .hour], from: referenceDate)
        XCTAssertEqual(japaneseComponents.year, 8, "令和年號應為 8（西元 2026 年）——證明 bug 場景是真的")
        let pickedDate = try XCTUnwrap(japanese.date(from: japaneseComponents))
        XCTAssertEqual(pickedDate, referenceDate, "和曆重建應與西曆原始時間點是同一個絕對時間")

        XCTAssertEqual(BirthdayFormat.wireString(from: pickedDate, timeZone: timeZone), "2026-09-19")
    }

    /// 反向：解析 `"2026-09-19"` 得到的 `Date` 在民國曆／佛曆／和曆下都要 round-trip 回同一個
    /// 絕對時間點——`date(fromWireString:)` 用固定西曆＋UTC 解析（本來就沒有 `.current` 依賴），
    /// 這裡確認解析結果不會因為之後拿哪種曆法去讀它而漂移。
    func test_dateFromWireString_sameDayAcrossNonGregorianCalendars() throws {
        let parsed = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2026-09-19"))

        for identifier: Calendar.Identifier in [.republicOfChina, .buddhist, .japanese] {
            var altCalendar = Calendar(identifier: identifier)
            altCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
            let components = altCalendar.dateComponents([.era, .year, .month, .day], from: parsed)
            let roundTripped = try XCTUnwrap(altCalendar.date(from: components))
            XCTAssertEqual(roundTripped, parsed, "\(identifier) 曆法下抽出年月日重建後應仍是同一天")
        }
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

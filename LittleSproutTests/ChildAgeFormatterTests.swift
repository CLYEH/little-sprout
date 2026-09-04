import Foundation
@testable import LittleSprout
import XCTest

/// LS-169：年齡標記邊界測試——`BirthdayFormat.ageDescription` 已經是純函式（時間軸底部
/// 年齡列 `ChildrenManagementView.childRowContent`／`sidebarContent`，多寶貝 caption
/// `MultiChildCaptionFormatter.segments` 都吃它），這裡補票文點名的五類邊界，既有
/// `BirthdayFormatTests`／`MultiChildCaptionFormatterTests` 沒蓋到：生日當天、未滿一個月、
/// 閏年 2/29 生日在平年、月底生日跨月（1/31→2 月）、跨年。全程固定 UTC `Calendar`，不用
/// 裝置目前時區／`Date()`，避免因為跑測試當下的日期而 flake。
///
/// 每個案例的期望值先用同一套 `Calendar.dateComponents([.year, .month], from:to:)` 邏輯
/// 實測算出（不是猜的字面值）——這是 Foundation 曆法計算本身的行為，測試在意的是「這支
/// 純函式在這些邊界上的輸出被鎖住、之後改動會被看見」，不是重新驗證 Foundation 的正確性。
final class ChildAgeFormatterTests: XCTestCase {
    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ wireString: String) -> Date {
        BirthdayFormat.date(fromWireString: wireString)!
    }

    /// 生日當天：0 歲 0 個月，退回「0 個月大」（既有規則：`years == 0` 一律走「X 個月大」
    /// 措辭，不會顯示「0 歲」）。
    func test_ageDescription_onBirthday_returnsZeroMonthsOld() {
        let birthday = date("2024-06-15")
        let today = date("2024-06-15")
        let age = BirthdayFormat.ageDescription(birthday: birthday, now: today, calendar: utcCalendar())

        XCTAssertEqual(age, "0 個月大")
    }

    /// 未滿一個月，且跨過一次月份邊界（5/25 出生、6/20 現在，26 天，還沒滿一個月）——
    /// 確認「跨月份」本身不會被誤算成「滿一個月」，真正的判準是有沒有到達同一個
    /// day-of-month。
    func test_ageDescription_underOneMonth_crossingMonthBoundary_returnsZeroMonthsOld() {
        let birthday = date("2024-05-25")
        let today = date("2024-06-20")
        let age = BirthdayFormat.ageDescription(birthday: birthday, now: today, calendar: utcCalendar())

        XCTAssertEqual(age, "0 個月大")
    }

    /// 閏年 2/29 生日、隔年是平年（沒有 2/29）：滿週歲的那天落在平年的 2/28（Foundation
    /// 把「差一整年」對齊到當月的最後一天，不是延後到 3/1）——這個邊界如果算錯，最常見
    /// 的錯法是誤判成還沒滿一歲（少算一個月／一年）。
    func test_ageDescription_leapDayBirthday_turnsOneOnFeb28OfNonLeapYear() {
        let birthday = date("2024-02-29")
        let firstBirthday = date("2025-02-28")
        let age = BirthdayFormat.ageDescription(birthday: birthday, now: firstBirthday, calendar: utcCalendar())

        XCTAssertEqual(age, "1 歲")
    }

    /// 同一個閏年生日、第二年（2026 一樣是平年）：確認不是只有第一次跨閏年才對，往後
    /// 每一年都穩定用 2/28 當滿週歲的那天。
    func test_ageDescription_leapDayBirthday_secondNonLeapYear_turnsTwo() {
        let birthday = date("2024-02-29")
        let secondBirthday = date("2026-02-28")
        let age = BirthdayFormat.ageDescription(birthday: birthday, now: secondBirthday, calendar: utcCalendar())

        XCTAssertEqual(age, "2 歲")
    }

    /// 月底生日跨月（1/31 生日，平年 2 月只有 28 天）：滿一個月的那天落在 2/28（沒有
    /// 2/31 可以對齊），這是「月底生日碰到較短的下個月」這一整類邊界的代表案例。
    func test_ageDescription_monthEndBirthday_turnsOneMonthOnFeb28OfNonLeapYear() {
        let birthday = date("2023-01-31")
        let oneMonthLater = date("2023-02-28")
        let age = BirthdayFormat.ageDescription(birthday: birthday, now: oneMonthLater, calendar: utcCalendar())

        XCTAssertEqual(age, "1 個月大")
    }

    /// 跨年（12 月生、隔年 1 月算年齡）：確認「歲」的計算跨過曆年邊界時不會算錯——這裡
    /// 選了一個乾淨滿一整年、沒有多餘月份的案例（2022-12-20 → 2024-01-05 是 1 歲整）。
    func test_ageDescription_acrossYearBoundary_wholeYearNoExtraMonths() {
        let birthday = date("2022-12-20")
        let today = date("2024-01-05")
        let age = BirthdayFormat.ageDescription(birthday: birthday, now: today, calendar: utcCalendar())

        XCTAssertEqual(age, "1 歲")
    }

    /// 跨年＋還有多餘月份的組合案例：確保「年」與「月」兩個分量在跨年情境下都各自算對，
    /// 不是只驗證其中一個分量剛好是 0 的簡單情況。
    func test_ageDescription_acrossYearBoundary_yearsAndMonths() {
        let birthday = date("2022-12-20")
        let today = date("2024-01-20")
        let age = BirthdayFormat.ageDescription(birthday: birthday, now: today, calendar: utcCalendar())

        XCTAssertEqual(age, "1 歲 1 個月")
    }
}

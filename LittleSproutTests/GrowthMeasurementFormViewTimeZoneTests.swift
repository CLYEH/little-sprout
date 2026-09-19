import Foundation
@testable import LittleSprout
import XCTest

/// LS-313 R1 merge-review M1：`GrowthMeasurementFormView` 編輯回填在負時區（America/New_York）
/// 會把 `editingRecord.measuredOn`（UTC 午夜）誤判成前一天——`localMidnight(from:calendar:)`
/// 文件註解有完整原因。這裡直接測那支純函式（同 `BirthdayFormatTests` 既有理由：注入固定
/// `calendar` 而不是改動全域 `TimeZone.current`）。
final class GrowthMeasurementFormViewTimeZoneTests: XCTestCase {
    private func easternCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// mutation：把 `localMidnight` 改回一律回傳 `utcDate`（不換算），這支測試轉紅——UTC 午夜
    /// 的 2026-09-04 用紐約時區（UTC-4）直接抽年月日會變成 2026-09-03。
    func test_localMidnight_negativeOffsetTimeZone_keepsSameCalendarDay() throws {
        let utcDate = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2026-09-04"))

        let localDate = try XCTUnwrap(
            GrowthMeasurementFormView.localMidnight(from: utcDate, calendar: easternCalendar())
        )
        let components = easternCalendar().dateComponents([.year, .month, .day], from: localDate)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 4, "紐約時區（UTC-4）抽年月日仍要是 4 日，不能退回 3 日")
    }

    /// 完整往返：回填後直接按儲存（不動日期）——`localMidnight` 的結果再送進
    /// `BirthdayFormat.wireString(from:calendar:)`（`GrowthMeasurementFormView.submit()` 實際
    /// 呼叫的那支）要拿回同一個 `"yyyy-MM-dd"`，這才是使用者真正會踩到的路徑。
    func test_localMidnight_roundTripsThroughWireStringInNegativeOffsetTimeZone() throws {
        let utcDate = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2026-09-04"))

        let localDate = try XCTUnwrap(
            GrowthMeasurementFormView.localMidnight(from: utcDate, calendar: easternCalendar())
        )

        XCTAssertEqual(BirthdayFormat.wireString(from: localDate, calendar: easternCalendar()), "2026-09-04")
    }
}

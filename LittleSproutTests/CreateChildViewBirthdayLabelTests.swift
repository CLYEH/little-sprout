@testable import LittleSprout
import XCTest

/// LS-335 範圍 7（來源 LS-334 merge-review R2 i1 `c3e7fd18`）：`CreateChildView` 的 `birthday`
/// 來自 `DatePicker`（`.date` components），保留開畫面當下的本地時刻；送出走
/// `BirthdayFormat.wireString(from:)`（裝置時區抽年月日），標籤卻用 `displayString` 預設 UTC——
/// Asia/Taipei 當地 0:00–7:59 標籤比實際送出的日期早一天。標籤與送出必須是同一天。
/// mutation：`birthdayValueText(for:timeZone:)` 不傳 `timeZone`（回到預設 UTC），這支測試轉紅。
final class CreateChildViewBirthdayLabelTests: XCTestCase {
    func test_birthdayLabel_matchesSubmittedDay_acrossLocalTimesOfDay() throws {
        for identifier in ["Asia/Taipei", "Pacific/Kiritimati", "America/New_York", "UTC"] {
            let timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let dayStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 9, day: 19)))
            for hour in 0..<24 {
                let picked = try XCTUnwrap(calendar.date(byAdding: .hour, value: hour, to: dayStart))
                let submitted = try XCTUnwrap(
                    BirthdayFormat.date(fromWireString: BirthdayFormat.wireString(from: picked, timeZone: timeZone))
                )
                XCTAssertEqual(
                    CreateChildView.birthdayValueText(for: picked, timeZone: timeZone),
                    BirthdayFormat.displayString(from: submitted),
                    "\(identifier) 當地 \(hour) 時：生日欄標籤必須是實際送出的那一天"
                )
            }
        }
    }

    func test_birthdayLabel_nil_showsPlaceholder() {
        XCTAssertEqual(CreateChildView.birthdayValueText(for: nil), "選擇生日")
    }
}

@testable import LittleSprout
import XCTest

/// LS-334（LS-96 池項 `0a14168d`(1)，同 LS-313 R1 M1 型）：`EditChildView` 原本
/// `_birthday = State(initialValue: child.birthday)` 直接把 UTC 午夜的 `child.birthday` 塞進
/// 這個 `@State`，之後全程被當成「裝置本地時區的 Date」餵給 `BirthdayPickerSheet`／
/// `submit()` 的 `BirthdayFormat.wireString(from:timeZone:)`——裝置在負 UTC 時區時，這個 UTC
/// 午夜換算成本地時間是「前一天下午」，使用者不碰生日欄直接按「儲存變更」，`wireString`
/// 用本地時區重新抽年月日，會把這個位移的前一天當成「使用者選的那天」再次編碼，整整少一天。
///
/// 沒有 ViewInspector 測不到 `EditChildView.init` 實際寫入 `@State` 的值（同
/// `GrowthAgeNBSPRegressionTests` 文件註解點名的既有理由），這裡用原始碼文字守衛：mutation
/// 把 `_birthday = State(initialValue: BirthdayFormat.localMidnight(from: child.birthday))` 改回
/// `_birthday = State(initialValue: child.birthday)`，這支測試會抓到。
///
/// `BirthdayFormat.localMidnight(from:timeZone:)` 本體（純函式，UTC 午夜→本地午夜換算是否
/// 正確）的直接行為覆蓋見本檔 `test_seededBirthday_labelShowsSameCalendarDay`（merge-review R1
/// M2：`GrowthMeasurementFormViewTimeZoneTests` 先前宣稱的「等效覆蓋」不成立——那支測試呼叫的
/// 是 `GrowthMeasurementFormView.localMidnight`，是另一支函式，把 `BirthdayFormat.localMidnight`
/// 挖空成 no-op 不會讓它變紅。`GrowthMeasurementFormView.localMidnight` 現已收斂成直接呼叫
/// `BirthdayFormat.localMidnight`，見 `GrowthMeasurementFormViewTimeZoneTests
/// .test_localMidnight_source_delegatesToBirthdayFormat`，這裡不重複驗證換算本身，只驗接線。
final class EditChildViewBirthdayTimeZoneTests: XCTestCase {
    private func sourceText() throws -> String {
        let testFileURL = URL(fileURLWithPath: "\(#filePath)")
        let worktreeRoot = testFileURL
            .deletingLastPathComponent() // LittleSproutTests/
            .deletingLastPathComponent() // worktree 根目錄
        let sourceURL = worktreeRoot.appendingPathComponent("LittleSprout/Features/Children/EditChildView.swift")
        let fullText = try String(contentsOf: sourceURL, encoding: .utf8)
        return fullText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// mutation：把 `init` 內的 `_birthday` 賦值改回
    /// `_birthday = State(initialValue: child.birthday)`（不經 `localMidnight`），這支測試轉紅
    /// ——負 UTC 時區編輯既有孩子、不碰生日欄直接儲存會少一天。
    func test_init_seedsBirthdayThroughLocalMidnight_notRawUTCMidnight() throws {
        let source = try sourceText()

        XCTAssertTrue(
            source.contains("_birthday = State(initialValue: BirthdayFormat.localMidnight(from: child.birthday))"),
            "EditChildView.init 必須用 BirthdayFormat.localMidnight(from:) 把 child.birthday" +
                "（UTC 午夜）換成本地午夜再塞進 @State——直接塞 UTC 午夜，負 UTC 時區使用者不碰生日欄直接" +
                "儲存會少一天（LS-334）"
        )
        XCTAssertFalse(
            source.contains("_birthday = State(initialValue: child.birthday)"),
            "EditChildView.init 不應該再直接把 child.birthday（UTC 午夜）塞進 @State（LS-334）"
        )
    }

    /// merge-review R1 M1：`init` 改塞本地午夜之後，生日欄標籤（`EditChildView.swift:207`）
    /// 必須跟著改用裝置時區抽年月日。mutation：改回 `displayString(from: birthday)`
    /// （預設 UTC），這支測試轉紅。
    func test_birthdayField_labelUsesLocalTimeZone() throws {
        let source = try sourceText()
        XCTAssertTrue(
            source.contains("BirthdayFormat.displayString(from: birthday, timeZone: .current)"),
            "生日欄標籤必須用裝置時區抽年月日——`birthday` 這個 @State 是本地午夜（LS-334 R1 M1）"
        )
    }

    /// merge-review R1 M1（行為層）：`localMidnight` 換算出來的本地午夜，經生日欄標籤與
    /// `wireString` 兩條路都必須回到 DB 裡的同一天。head 現況在正 UTC 位移（Asia/Taipei
    /// UTC+8 是主客群）標籤少一天；把 `localMidnight` 改成 no-op 則負 UTC 位移
    /// （America/New_York）標籤與 wire 都少一天——兩個方向都由這支測試守住。
    func test_seededBirthday_labelShowsSameCalendarDay() throws {
        let stored = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2024-03-12"))
        let expected = BirthdayFormat.displayString(from: stored)
        for identifier in ["UTC", "Asia/Taipei", "Pacific/Kiritimati", "Asia/Kolkata",
                           "America/New_York", "Pacific/Pago_Pago"] {
            let timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
            let seeded = BirthdayFormat.localMidnight(from: stored, timeZone: timeZone)
            XCTAssertEqual(
                BirthdayFormat.displayString(from: seeded, timeZone: timeZone), expected,
                "\(identifier)：生日欄標籤必須顯示 DB 裡的那一天"
            )
            XCTAssertEqual(
                BirthdayFormat.wireString(from: seeded, timeZone: timeZone), "2024-03-12",
                "\(identifier)：不碰生日欄直接儲存必須寫回原日期"
            )
        }
    }
}

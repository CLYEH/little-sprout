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
/// 正確）已有等效覆蓋，見 `GrowthMeasurementFormViewTimeZoneTests
/// .test_localMidnight_negativeOffsetTimeZone_keepsSameCalendarDay` 的同型驗證
/// （`GrowthMeasurementFormView.localMidnight` 與 `BirthdayFormat.localMidnight` 算法逐字相同：
/// 固定西曆抽 UTC 年月日、再用固定西曆＋注入時區重組），這裡不重複驗證換算本身，只驗接線。
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
}

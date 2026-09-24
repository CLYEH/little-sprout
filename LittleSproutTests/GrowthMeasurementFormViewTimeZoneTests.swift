import Foundation
@testable import LittleSprout
import XCTest

/// LS-313 R1 merge-review M1：`GrowthMeasurementFormView` 編輯回填在負時區（America/New_York）
/// 會把 `editingRecord.measuredOn`（UTC 午夜）誤判成前一天——`localMidnight(from:timeZone:)`
/// 文件註解有完整原因。這裡直接測那支純函式（同 `BirthdayFormatTests` 既有理由：注入固定
/// `timeZone` 而不是改動全域 `TimeZone.current`）。
final class GrowthMeasurementFormViewTimeZoneTests: XCTestCase {
    private func easternTimeZone() -> TimeZone {
        TimeZone(identifier: "America/New_York")!
    }

    /// mutation：把 `localMidnight` 改回一律回傳 `utcDate`（不換算），這支測試轉紅——UTC 午夜
    /// 的 2026-09-04 用紐約時區（UTC-4）直接抽年月日會變成 2026-09-03。
    func test_localMidnight_negativeOffsetTimeZone_keepsSameCalendarDay() throws {
        let utcDate = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2026-09-04"))

        let localDate = GrowthMeasurementFormView.localMidnight(from: utcDate, timeZone: easternTimeZone())
        var easternCalendar = Calendar(identifier: .gregorian)
        easternCalendar.timeZone = easternTimeZone()
        let components = easternCalendar.dateComponents([.year, .month, .day], from: localDate)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 4, "紐約時區（UTC-4）抽年月日仍要是 4 日，不能退回 3 日")
    }

    /// 完整往返：回填後直接按儲存（不動日期）——`localMidnight` 的結果再送進
    /// `BirthdayFormat.wireString(from:timeZone:)`（`GrowthMeasurementFormView.submit()` 實際
    /// 呼叫的那支）要拿回同一個 `"yyyy-MM-dd"`，這才是使用者真正會踩到的路徑。
    func test_localMidnight_roundTripsThroughWireStringInNegativeOffsetTimeZone() throws {
        let utcDate = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2026-09-04"))

        let localDate = GrowthMeasurementFormView.localMidnight(from: utcDate, timeZone: easternTimeZone())

        XCTAssertEqual(BirthdayFormat.wireString(from: localDate, timeZone: easternTimeZone()), "2026-09-04")
    }

    // MARK: - LS-331 merge-review R1 X1：裝置曆法非西曆（民國／佛曆／和曆）編輯既有量測

    /// 根因：修好前的 `localMidnight(from:calendar: = .current)` 用裝置目前曆法重組回填日期
    /// ——裝置設成民國曆時，`Calendar(identifier: .republicOfChina).date(from:)` 把西曆年份
    /// 元件（2026）當成民國年重組，`localDate` 會落在西元 3937 年附近；舊版 `wireString`
    /// （同樣吃裝置曆法）剛好把這個錯抵銷，兩個 bug 相消看起來正常。LS-331 修好 `wireString`
    /// 之後抵銷消失，民國曆使用者編輯既有量測、不改日期直接按儲存，會把
    /// `2026-09-04` 存成 `3937-09-04`（`scratchpad/LS-313-ls331-interaction.swift` 用修好前的
    /// `localMidnight` 邏輯＋修好後的 `wireString` 實測：民國 `3937-09-04`／佛曆
    /// `1483-09-04`／和曆 `4044-09-04`）——`dateFieldLabel` 只顯示月日，使用者看不出來；
    /// `growth_records.measured_on` 沒有年份 `CHECK`，DB 照單全收。
    ///
    /// merge-review R1 M2：`localMidnight` 原本在這裡重新實作一次「固定西曆＋指定時區」的換算
    /// ——跟 `BirthdayFormat.localMidnight(from:timeZone:)`（`EditChildView` 同型 bug 的修法）
    /// 算法逐字相同，只差回傳型別，而且這份重複的實作完全沒有行為測試守著自己的邏輯本體（只靠
    /// `test_localMidnight_negativeOffsetTimeZone_keepsSameCalendarDay`／
    /// `test_localMidnight_roundTripsThroughWireStringInNegativeOffsetTimeZone` 兩支「黑箱」測試
    /// 從外部行為驗證，把 `localMidnight` 換算本體整支挖空成 no-op 這兩支測試也抓不到——見
    /// `BirthdayFormatTests` M2 討論）。收斂成直接呼叫 `BirthdayFormat.localMidnight`，只留一份
    /// 實作，換算本身的行為覆蓋交給 `BirthdayFormatTests`／
    /// `EditChildViewBirthdayTimeZoneTests.test_seededBirthday_labelShowsSameCalendarDay`（該測試
    /// 直接把 `localMidnight` 挖空成 no-op 會轉紅）。這裡改成原始碼文字守衛：mutation 把
    /// `localMidnight` 本體改回自行用 `Calendar(identifier: .gregorian)` 重組（不呼叫
    /// `BirthdayFormat.localMidnight`），這支測試轉紅——確保接線沒有被繞過、不會又漂移出第二份
    /// 重複實作。
    func test_localMidnight_source_delegatesToBirthdayFormat() throws {
        let testFileURL = URL(fileURLWithPath: "\(#filePath)")
        let worktreeRoot = testFileURL
            .deletingLastPathComponent() // LittleSproutTests/
            .deletingLastPathComponent() // worktree 根目錄
        let sourceURL = worktreeRoot.appendingPathComponent(
            "LittleSprout/Features/Growth/GrowthMeasurementFormView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let code = try functionBody(in: source, signaturePrefix: "static func localMidnight(")
        XCTAssertTrue(
            code.contains("BirthdayFormat.localMidnight(from: utcDate, timeZone: timeZone)"),
            "localMidnight 必須直接委派給 BirthdayFormat.localMidnight，不能自行重組一份西曆換算" +
                "（LS-334 merge-review R1 M2：重複實作會各自漂移，且完全沒有行為測試守著）"
        )
        XCTAssertFalse(
            code.contains("Calendar(identifier: .gregorian)"),
            "localMidnight 不得自行組 Calendar——換算邏輯只能活在 BirthdayFormat.localMidnight 這一份" +
                "（LS-334 merge-review R1 M2）"
        )
        // LS-335（LS-331 merge-review R2 `ab72a0f8` m1）：保留委派字面、再用
        // `var local: Calendar = .current` 重組的寫法，上面兩條都不命中。
        assertNoDeviceCalendar(code, in: "GrowthMeasurementFormView.localMidnight")
    }

    /// 從原始碼抽出一個函式的本體（簽名到同縮排層級的結尾大括號），過濾掉註解行——同
    /// `BirthdayFormatTests.test_wireString_source_extractsWithFixedGregorianCalendar` 與
    /// `GrowthAgeNBSPRegressionTests` 既有的原始碼文字守衛慣例。`closeBraceMarker` 依函式縮排
    /// 層級而異——struct 內的方法是 4 空白（`"\n    }"`），檔案層級的自由函式是 0 空白（`"\n}"`）。
    private func functionBody(
        in source: String, signaturePrefix: String, closeBraceMarker: String = "\n    }"
    ) throws -> String {
        let afterSignature = try XCTUnwrap(source.components(separatedBy: signaturePrefix).dropFirst().first)
        let region = try XCTUnwrap(afterSignature.components(separatedBy: closeBraceMarker).first)
        return region.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

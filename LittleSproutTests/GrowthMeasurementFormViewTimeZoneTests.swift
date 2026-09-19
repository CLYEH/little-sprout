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

        let localDate = try XCTUnwrap(
            GrowthMeasurementFormView.localMidnight(from: utcDate, timeZone: easternTimeZone())
        )
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

        let localDate = try XCTUnwrap(
            GrowthMeasurementFormView.localMidnight(from: utcDate, timeZone: easternTimeZone())
        )

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
    /// 修法同 `wireString`：`localMidnight` 一律用固定 `Calendar(identifier: .gregorian)`
    /// 重組，只借用注入的 `timeZone`——曆法識別碼結構上不再可能流進這支函式，行為層因此無法
    /// 用任何 `Calendar` 注入重現這個 bug（跟 `BirthdayFormatTests
    /// .test_wireString_source_extractsWithFixedGregorianCalendar` 同樣的盲區），改用原始碼
    /// 文字守衛：mutation 把 `Calendar(identifier: .gregorian)` 改回 `Calendar.current`／
    /// `.autoupdatingCurrent`，或重新開放注入 `Calendar`，這支測試轉紅。「固定西曆＋指定時區」
    /// 組合抽到檔案層級的 `fixedGregorianCalendar(timeZone:)`（避免 `localMidnight` 重複兩次、
    /// 也避免 `GrowthMeasurementFormView` struct body 過長），所以這裡分兩段守：
    /// `fixedGregorianCalendar` 本體要用固定西曆；`localMidnight` 本體要呼叫它、不能繞過去。
    func test_localMidnight_source_reconstructsWithFixedGregorianCalendar() throws {
        let testFileURL = URL(fileURLWithPath: "\(#filePath)")
        let worktreeRoot = testFileURL
            .deletingLastPathComponent() // LittleSproutTests/
            .deletingLastPathComponent() // worktree 根目錄
        let sourceURL = worktreeRoot.appendingPathComponent(
            "LittleSprout/Features/Growth/GrowthMeasurementFormView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let helperCode = try functionBody(
            in: source, signaturePrefix: "private func fixedGregorianCalendar(", closeBraceMarker: "\n}"
        )
        XCTAssertTrue(
            helperCode.contains("Calendar(identifier: .gregorian)"),
            "fixedGregorianCalendar 必須用固定西曆組 Calendar（LS-331 merge-review R1 X1）"
        )

        let code = try functionBody(in: source, signaturePrefix: "static func localMidnight(")
        XCTAssertTrue(
            code.contains("fixedGregorianCalendar(timeZone:"),
            "localMidnight 必須透過 fixedGregorianCalendar(timeZone:) 重組回填日期，不能繞過去直接" +
                "組裝置曆法的 Calendar（LS-331 merge-review R1 X1）"
        )

        for forbidden in ["Calendar.current", ".autoupdatingCurrent", "calendar: Calendar"] {
            XCTAssertFalse(
                code.contains(forbidden),
                "localMidnight 不得出現 \(forbidden)——裝置曆法會流進回填日期，跟 wireString 修好後" +
                    "會把 2026-09-04 存成 3937-09-04（LS-331 merge-review R1 X1）"
            )
            XCTAssertFalse(
                helperCode.contains(forbidden),
                "fixedGregorianCalendar 不得出現 \(forbidden)——裝置曆法會流進所有借用它的呼叫端" +
                    "（LS-331 merge-review R1 X1）"
            )
        }
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

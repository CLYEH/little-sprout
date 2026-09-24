import XCTest

/// LS-335（LS-331 merge-review R2 `ab72a0f8` m1）：原始碼文字守衛共用的「不得借用裝置曆法」檢查——
/// `BirthdayFormatTests` 與 `GrowthMeasurementFormViewTimeZoneTests` 共用同一份禁用清單，不各自漂移。
/// 舊版只禁 `Calendar.current`／`.autoupdatingCurrent`／`calendar: Calendar` 三個字面，下列寫法都
/// 不命中：`var local: Calendar = .current`、`calendar = .current`（隱式成員）、在區段外取
/// `Calendar.current.identifier` 再於區段內 `Calendar(identifier: deviceCalendarID)`（間接）。
/// 這裡先剝掉簽名預設值 `timeZone: TimeZone = .current`（那是時區、不是曆法），其餘 `.current`
/// 一律禁止，另禁 `autoupdatingCurrent`／`Locale`／`calendar: Calendar`；所有 `Calendar(identifier:`
/// 都必須是 `.gregorian`。殘餘限制：更深的間接（例如另一個檔案的 helper 回傳裝置曆法）仍抓不到，
/// 行為層根治是 `-AppleLocale` test plan（LS-96 `9e3855ec`）。
func assertNoDeviceCalendar(_ body: String, in name: String, file: StaticString = #filePath, line: UInt = #line) {
    let checked = body.replacingOccurrences(of: "TimeZone = .current", with: "")
    XCTAssertEqual(
        checked.components(separatedBy: "Calendar(identifier:").count,
        checked.components(separatedBy: "Calendar(identifier: .gregorian)").count,
        "\(name) 只能用 .gregorian 建 Calendar——裝置曆法會流進 wire 年份／回填日期（LS-331／LS-335）",
        file: file, line: line
    )
    for forbidden in [".current", "autoupdatingCurrent", "Locale", "calendar: Calendar"] {
        XCTAssertFalse(
            checked.contains(forbidden),
            "\(name) 不得出現 \(forbidden)——裝置曆法會流進 wire 年份／回填日期（LS-331／LS-335）",
            file: file, line: line
        )
    }
}

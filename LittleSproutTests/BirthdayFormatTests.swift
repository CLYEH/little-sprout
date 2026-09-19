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
        let gregorianUTCMidnight = try XCTUnwrap(
            utcCalendar().date(from: DateComponents(year: 2026, month: 9, day: 19))
        )
        XCTAssertEqual(parsed, gregorianUTCMidnight, "wire 字串必須以固定西曆解析——不是裝置曆法的「2026 年」（LS-331）")

        for identifier: Calendar.Identifier in [.republicOfChina, .buddhist, .japanese] {
            var altCalendar = Calendar(identifier: identifier)
            altCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
            let components = altCalendar.dateComponents([.era, .year, .month, .day], from: parsed)
            let roundTripped = try XCTUnwrap(altCalendar.date(from: components))
            XCTAssertEqual(roundTripped, parsed, "\(identifier) 曆法下抽出年月日重建後應仍是同一天")
        }
    }

    /// LS-331 merge-review R1：上面三支曆法測試餵給 `wireString` 的是同一個絕對時間點＋同一個時區，
    /// 測試程序裡 `Calendar.current` 恆為西曆（CI／本機模擬器皆是），所以「`wireString` 內部改回
    /// `Calendar.current` 抽年月日」這個回歸在行為層測不到（測試程序無法安全切換 `Calendar.current`）。
    /// 比照 `GrowthAgeNBSPRegressionTests` 既有的原始碼文字守衛：mutation 把
    /// `Calendar(identifier: .gregorian)` 改回 `Calendar.current`／`.autoupdatingCurrent`，或重新開放
    /// 注入 `Calendar`，這支測試轉紅。
    ///
    /// LS-334：`fixedGregorianCalendar(timeZone:)` 抽成 `wireString`／`ageDescription` 共用的
    /// private helper 之後，`wireString` 本體不再直接出現 `Calendar(identifier: .gregorian)`
    /// 字面──改成兩段守：helper 本體要用固定西曆組 `Calendar`；`wireString` 本體要呼叫
    /// `fixedGregorianCalendar(timeZone:)`、不能繞過去（同
    /// `GrowthMeasurementFormViewTimeZoneTests.test_localMidnight_source_delegatesToBirthdayFormat`
    /// 既有的原始碼文字守衛理由）。
    func test_wireString_source_extractsWithFixedGregorianCalendar() throws {
        let source = try birthdayFormatSource()

        let helperCode = try functionBody(in: source, signaturePrefix: "private static func fixedGregorianCalendar(")
        XCTAssertTrue(
            helperCode.contains("Calendar(identifier: .gregorian)"),
            "fixedGregorianCalendar 必須用固定西曆組 Calendar（LS-331／LS-334）"
        )

        let code = try functionBody(
            in: source, signaturePrefix: "static func wireString(from pickedDate: Date, timeZone:"
        )
        XCTAssertTrue(
            code.contains("fixedGregorianCalendar(timeZone: timeZone)"),
            "wireString 必須透過 fixedGregorianCalendar(timeZone:) 抽年月日，不能繞過去直接組裝置曆法的" +
                " Calendar（LS-331／LS-334）"
        )

        for forbidden in ["Calendar.current", ".autoupdatingCurrent", "calendar: Calendar"] {
            XCTAssertFalse(
                code.contains(forbidden), "wireString 不得出現 \(forbidden)——裝置曆法會流進 wire 年份（LS-331）"
            )
            XCTAssertFalse(
                helperCode.contains(forbidden),
                "fixedGregorianCalendar 不得出現 \(forbidden)——裝置曆法會流進所有借用它的呼叫端（LS-331／LS-334）"
            )
        }
    }

    /// 讀取 `BirthdayFormat.swift` 原始碼——`test_wireString_source_extractsWithFixedGregorianCalendar`／
    /// `test_ageDescription_source_extractsWithFixedGregorianCalendar` 共用同一份檔案內容。
    private func birthdayFormatSource() throws -> String {
        let sourceURL = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent() // LittleSproutTests/
            .deletingLastPathComponent() // worktree 根目錄
            .appendingPathComponent("LittleSprout/Support/BirthdayFormat.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    /// 從原始碼抽出一個函式的本體（簽名到同縮排層級的結尾大括號），過濾掉註解行——同
    /// `GrowthMeasurementFormViewTimeZoneTests` 既有的原始碼文字守衛慣例。
    private func functionBody(
        in source: String, signaturePrefix: String, closeBraceMarker: String = "\n    }"
    ) throws -> String {
        let afterSignature = try XCTUnwrap(source.components(separatedBy: signaturePrefix).dropFirst().first)
        let region = try XCTUnwrap(afterSignature.components(separatedBy: closeBraceMarker).first)
        return region.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
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

        XCTAssertEqual(
            BirthdayFormat.ageDescription(birthday: birthday, now: now, timeZone: utcCalendar().timeZone), "2 歲"
        )
    }

    func test_ageDescription_yearsAndMonths_includesBoth() {
        let birthday = BirthdayFormat.date(fromWireString: "2022-01-01")!
        let now = BirthdayFormat.date(fromWireString: "2024-04-15")!

        XCTAssertEqual(
            BirthdayFormat.ageDescription(birthday: birthday, now: now, timeZone: utcCalendar().timeZone),
            "2 歲 3 個月"
        )
    }

    func test_ageDescription_underOneYear_usesMonthsOnlyPhrasing() {
        let birthday = BirthdayFormat.date(fromWireString: "2023-09-12")!
        let now = BirthdayFormat.date(fromWireString: "2024-03-12")!

        XCTAssertEqual(
            BirthdayFormat.ageDescription(birthday: birthday, now: now, timeZone: utcCalendar().timeZone), "6 個月大"
        )
    }

    /// `now` 用「使用者現在的今天」（呼叫端注入的 `timeZone` 抽出的年月日）而不是 `Date()` 的
    /// 原始 UTC 瞬間——不然在 UTC+13 剛過午夜的使用者，用 UTC 瞬間算出來的「今天」還是前一天，
    /// 生日當天算出來的年齡會少一天可能造成月份少算。
    func test_ageDescription_usesCallerLocalTimeZoneForToday() {
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

        XCTAssertEqual(
            BirthdayFormat.ageDescription(birthday: birthday, now: nowLocal, timeZone: localCal.timeZone), "2 歲"
        )
    }

    // MARK: - LS-334：裝置曆法非西曆時年齡算術（民國／佛曆／和曆）

    /// 生日 2024-03-12、今天 2026-09-19（LS-334 票文指定的實測組合）：西曆算出來是「2 歲 6
    /// 個月」。這裡直接呼叫 internal 的 `extractionCalendar:` 重載（只給測試注入非西曆曆法，
    /// 見該函式文件註解）重現舊行為的根因——曆法識別碼一旦流進「抽今天年月日」這一步，
    /// `.year` 元件是曆法原生年號，被直接塞進固定西曆的 `utcCalendar.date(from:)` 建構「今天
    /// UTC 午夜」，算出來的不是真正的西元今天。production 只會呼叫 `timeZone:` 版本，同一組
    /// 輸入透過它得到的必須是對的「2 歲 6 個月」——不管裝置曆法設成什麼，曆法識別碼結構上
    /// 進不去。
    func test_ageDescription_republicOfChinaExtractionCalendar_reproducesOldZeroMonthsBug() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Taipei"))
        let birthday = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2024-03-12"))
        let now = try referenceNow(timeZone: timeZone)
        let roc = nonGregorianCalendar(.republicOfChina, timeZoneIdentifier: "Asia/Taipei")

        let buggy = BirthdayFormat.ageDescription(birthday: birthday, now: now, extractionCalendar: roc)
        XCTAssertEqual(
            buggy, "0 個月大",
            "重現 LS-334 舊行為：民國曆年份元件（115）流進抽取步驟，比生日西元年還早，被 max(0, …) 夾成 0"
        )

        let fixed = BirthdayFormat.ageDescription(birthday: birthday, now: now, timeZone: timeZone)
        XCTAssertEqual(fixed, "2 歲 6 個月", "production 入口固定西曆抽取，同一組輸入不受裝置曆法影響")
    }

    /// 同上，佛曆（泰國）：`.year` 元件是西元年+543，舊行為會多算出「N+543 歲」。
    func test_ageDescription_buddhistExtractionCalendar_reproducesOldOversizedAgeBug() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Taipei"))
        let birthday = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2024-03-12"))
        let now = try referenceNow(timeZone: timeZone)
        let buddhist = nonGregorianCalendar(.buddhist, timeZoneIdentifier: "Asia/Taipei")

        let buggy = BirthdayFormat.ageDescription(birthday: birthday, now: now, extractionCalendar: buddhist)
        XCTAssertEqual(
            buggy, "545 歲 6 個月",
            "重現 LS-334 舊行為：佛曆年份元件（2569）比西元年多 543，年齡多算出 545 歲"
        )

        let fixed = BirthdayFormat.ageDescription(birthday: birthday, now: now, timeZone: timeZone)
        XCTAssertEqual(fixed, "2 歲 6 個月", "production 入口固定西曆抽取，同一組輸入不受裝置曆法影響")
    }

    /// 同上，和曆（令和）：`.year` 元件是令和年號（西元 2026 年是令和 8 年），跟民國曆同型
    /// （比生日西元年還早，夾成 0）。
    func test_ageDescription_japaneseExtractionCalendar_reproducesOldZeroMonthsBug() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Taipei"))
        let birthday = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2024-03-12"))
        let now = try referenceNow(timeZone: timeZone)
        let japanese = nonGregorianCalendar(.japanese, timeZoneIdentifier: "Asia/Taipei")

        let buggy = BirthdayFormat.ageDescription(birthday: birthday, now: now, extractionCalendar: japanese)
        XCTAssertEqual(
            buggy, "0 個月大",
            "重現 LS-334 舊行為：令和年號（8）流進抽取步驟，比生日西元年還早，被 max(0, …) 夾成 0"
        )

        let fixed = BirthdayFormat.ageDescription(birthday: birthday, now: now, timeZone: timeZone)
        XCTAssertEqual(fixed, "2 歲 6 個月", "production 入口固定西曆抽取，同一組輸入不受裝置曆法影響")
    }

    /// LS-334 票文指定的「今天」：2026-09-19（Asia/Taipei 上午 10 點，避免剛好卡在日界模糊）。
    private func referenceNow(timeZone: TimeZone) throws -> Date {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        return try XCTUnwrap(gregorian.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 10)))
    }

    /// LS-334：`ageDescription` 原始碼文字守衛——同
    /// `test_wireString_source_extractsWithFixedGregorianCalendar` 的既有理由，測試程序裡
    /// `Calendar.current` 恆為西曆，「production 入口改回吃 `Calendar.current`」這個回歸無法
    /// 用任何 `Calendar` 注入在行為層重現，改用原始碼文字守衛：mutation 把
    /// `fixedGregorianCalendar(timeZone: timeZone)` 改回 `Calendar.current`／
    /// `.autoupdatingCurrent`，或重新開放注入 `calendar: Calendar` 參數，這支測試轉紅。
    func test_ageDescription_source_extractsWithFixedGregorianCalendar() throws {
        let source = try birthdayFormatSource()
        let code = try functionBody(
            in: source,
            signaturePrefix: "static func ageDescription(birthday: Date, now: Date = Date(), timeZone:",
            closeBraceMarker: "\n    static func ageDescription(birthday: Date, now: Date,"
        )

        XCTAssertTrue(
            code.contains("fixedGregorianCalendar(timeZone: timeZone)"),
            "ageDescription 的 production 入口必須用 fixedGregorianCalendar(timeZone: timeZone) 抽取（LS-334）"
        )
        for forbidden in ["Calendar.current", ".autoupdatingCurrent", "calendar: Calendar"] {
            XCTAssertFalse(
                code.contains(forbidden),
                "ageDescription 的 production 入口不得出現 \(forbidden)——裝置曆法會流進年齡算術（LS-334）"
            )
        }
    }
}

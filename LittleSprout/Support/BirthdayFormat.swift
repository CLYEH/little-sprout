import Foundation

/// `children.birthday` 是 Postgres `date` 欄位（無時區），但 supabase-swift 預設的
/// `JSONDecoder`/`JSONEncoder`（`Codable.swift` `.supabase()`）只認得含時間的 ISO8601
/// 字串（`yyyy-MM-dd'T'HH:mm:ss[.SSS]`），對純日期字串（`"2024-03-12"`）會直接
/// `DecodingError`。同時，SwiftUI 的 `DatePicker` 綁定的是裝置**本地時區**的 `Date`：
/// 若照舊用 SDK 預設編碼（一律轉成 UTC ISO8601），使用者在 UTC+8 選的「3 月 12 日」會被轉成
/// 「3 月 11 日 16:00 UTC」，送到後端 `::date` 轉型後變成 3 月 11 日——跨夜位移的生日錯誤。
///
/// 這裡刻意把 `birthday` 全程用「UTC 固定時區」代表「一個日曆日」：只在使用者從
/// `DatePicker`（local time）選出新日期那一刻，用固定西曆＋（可注入的）本地時區抽出年月日
/// （使用者實際選的那一天——曆法固定西曆是 LS-331 修正，見 `wireString` 文件註解），之後的
/// 字串化／解析／顯示一律用 UTC，不再受裝置時區影響——兩段刻意用不同 calendar，切換的界線
/// 只有這一處。
enum BirthdayFormat {
    private static let wireFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 把 `DatePicker` 選出的（裝置本地時區）`Date` 轉成 RPC 要送出的 `"yyyy-MM-dd"` 字串。
    ///
    /// LS-331：年月日一律用固定的 `Calendar(identifier: .gregorian)` 抽取，只借用（可注入的）
    /// `timeZone` 決定「哪一天」——裝置若把曆法設成民國曆／佛曆／和曆，`Calendar.current` 的
    /// `.year` 元件會是曆法原生年號（115／2569／8），若直接拿來組字串送出去，DB 存的年份就
    /// 壞掉。呼叫端要注入時區就注入 `TimeZone`，不注入 `Calendar`——這樣曆法識別碼永遠不會
    /// 有機會流進這支函式，結構上排除了整類 bug，不是只防目前已知的三種曆法。
    static func wireString(from pickedDate: Date, timeZone: TimeZone = .current) -> String {
        var extractionCalendar = Calendar(identifier: .gregorian)
        extractionCalendar.timeZone = timeZone
        let components = extractionCalendar.dateComponents([.year, .month, .day], from: pickedDate)
        let utcDate = utcCalendar.date(from: components) ?? pickedDate
        return wireFormatter.string(from: utcDate)
    }

    /// 把 RPC／`list_children` 回傳的 `"yyyy-MM-dd"` 字串解析成 `Date`（UTC 午夜）。
    static func date(fromWireString string: String) -> Date? {
        wireFormatter.date(from: string)
    }

    /// 顯示用「2024年3月12日」——固定用 UTC 抽年月日，不吃裝置時區（否則同一個 `Date`
    /// 在不同時區的裝置上可能顯示成前一天／後一天）。
    static func displayString(from date: Date, locale: Locale = Locale(identifier: "zh_Hant_TW")) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "y年M月d日"
        return formatter.string(from: date)
    }

    /// 「2 歲 3 個月」／「6 個月大」——年月差以 UTC 曆法計算；`now` 先用 `calendar`
    /// （預設裝置本地時區，代表「使用者現在的今天」）抽出年月日，再換成 UTC 午夜跟
    /// `birthday`（已是 UTC 午夜）比較，兩邊都化成「UTC 的一個日曆日」才不會因為時差
    /// 多算或少算一天。
    static func ageDescription(birthday: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let todayComponents = calendar.dateComponents([.year, .month, .day], from: now)
        let todayUTC = utcCalendar.date(from: todayComponents) ?? now
        let diff = utcCalendar.dateComponents([.year, .month], from: birthday, to: todayUTC)
        let years = max(0, diff.year ?? 0)
        let months = max(0, diff.month ?? 0)
        if years == 0 {
            return "\(months) 個月大"
        } else if months == 0 {
            return "\(years) 歲"
        } else {
            return "\(years) 歲 \(months) 個月"
        }
    }
}

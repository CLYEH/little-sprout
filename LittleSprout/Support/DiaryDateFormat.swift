import Foundation

/// 日記編輯器「記錄日期」欄位顯示文字（`design/littlesprout.pen` `LS-21 / 12` Date Field：
/// `"8月31日（今天）"`）——用裝置本地時區判斷「是不是今天」（使用者填的是他自己那天寫了什麼，
/// 跟 `BirthdayFormat` 刻意固定 UTC 代表「一個日曆日」的理由不同：生日是一個跟時區無關的
/// 事實，記錄日期則是「使用者現在的今天」，兩者故意不共用同一顆判斷用的 calendar）。
enum DiaryDateFormat {
    private static func formatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "M月d日"
        return formatter
    }

    /// `calendar`／`now` 皆可覆寫供測試釘住「今天」判斷，不依賴實際牆鐘時間。
    static func displayString(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = Locale(identifier: "zh_Hant_TW")
    ) -> String {
        let base = formatter(locale: locale).string(from: date)
        return calendar.isDate(date, inSameDayAs: now) ? "\(base)（今天）" : base
    }
}

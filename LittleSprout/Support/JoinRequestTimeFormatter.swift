import Foundation

/// Owner 審核清單（`design/littlesprout.pen` frame `NRLL3`）每筆申請的送出時間顯示：同一天內用
/// 「N 分鐘前／N 小時前」相對時間，較早則退回「昨天 HH:mm」或「M/d HH:mm」絕對時間——長輩不需要
/// 心算「3 小時前」跟「昨天晚上」哪個比較久，但也不需要每筆都精算到分鐘。
enum JoinRequestTimeFormatter {
    static func format(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if calendar.isDate(date, inSameDayAs: now) {
            return relative(seconds: seconds)
        }
        // `Calendar.isDateInYesterday` 永遠對照系統當下的真實日期，不吃自訂的 `now`——測試（與
        // 未來若需要「假裝現在是某個時間」的情境）都必須靠這行手動算出「`now` 的前一天」，不能
        // 直接呼叫那支 API（R1 實測：注入過去的 `now` 時，`isDateInYesterday` 仍然拿系統今天
        // 比較，導致明明相差一天卻判定不是昨天）。
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        if let yesterday, calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(timeOfDay(date, calendar: calendar))"
        }
        return "\(monthDay(date, calendar: calendar)) \(timeOfDay(date, calendar: calendar))"
    }

    private static func relative(seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 {
            return "剛剛"
        }
        if minutes < 60 {
            return "\(minutes) 分鐘前"
        }
        return "\(minutes / 60) 小時前"
    }

    private static func timeOfDay(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private static func monthDay(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)/\(components.day ?? 0)"
    }
}

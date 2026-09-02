import Foundation

/// 日記編輯器影片時長格式──`design/littlesprout.pen` `LS-21 / 12*` 系列徽章／回話文案的
/// 「M:SS」格式（`0:32`／`1:24`），與系統 `Duration.TimeFormatStyle` 不同源，這裡自己寫是因為
/// 需要固定「不補前導零的分鐘數＋兩位數秒」這個特定形狀，且要能在純函式層被單元測試釘住。
enum DiaryDurationFormat {
    /// 60 秒上限（`docs/API.md` LS-125 票文 Scope 3：發佈時只保留前 60 秒）。
    static let maxPublishDuration: TimeInterval = 60

    /// `92.7` 秒 → `"1:32"`（無條件捨去到秒，不四捨五入——`M:SS` 是給人看的粗略時長，不是
    /// 精確時間戳，捨去比進位更符合「這支影片還有多長」的直覺）。
    static func string(from duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func exceedsMaxPublishDuration(_ duration: TimeInterval) -> Bool {
        duration > maxPublishDuration
    }
}

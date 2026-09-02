import Foundation

/// 「影片 M:SS」徽章文字（LS-126 票文 Scope 1）——`media` 表沒有 `duration` 欄位，時長是
/// `TimelineStore.loadVideoDuration` 向簽名 URL 讀 `AVURLAsset` 得到的，這裡只負責格式化。
enum VideoDurationFormat {
    /// `duration` 為 nil（尚未讀到，或讀取失敗）時只顯示「影片」，不掛假的 0:00。
    ///
    /// merge-review R1 i2：無條件捨去到秒，**不四捨五入**——對齊 LS-125
    /// `DiaryDurationFormat.string(from:)` 的既有慣例（同一支影片在編輯器與時間軸卡片本來
    /// 應該顯示同一個數字）。理由同該檔文件註解：`M:SS` 是給人看的粗略時長，不是精確時間戳，
    /// 捨去比進位更符合「這支影片還有多長」的直覺。
    static func badgeText(duration: TimeInterval?) -> String {
        guard let duration else { return "影片" }
        let totalSeconds = max(0, Int(duration))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "影片 %d:%02d", minutes, seconds)
    }
}

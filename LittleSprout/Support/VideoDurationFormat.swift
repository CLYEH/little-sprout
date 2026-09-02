import Foundation

/// 「影片 M:SS」徽章文字（LS-126 票文 Scope 1）——`media` 表沒有 `duration` 欄位，時長是
/// `TimelineStore.loadVideoDuration` 向簽名 URL 讀 `AVURLAsset` 得到的，這裡只負責格式化。
enum VideoDurationFormat {
    /// `duration` 為 nil（尚未讀到，或讀取失敗）時只顯示「影片」，不掛假的 0:00。
    static func badgeText(duration: TimeInterval?) -> String {
        guard let duration else { return "影片" }
        let totalSeconds = max(0, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "影片 %d:%02d", minutes, seconds)
    }
}

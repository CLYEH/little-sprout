import AVFoundation
import Foundation

/// 影片時長量測（`docs/API.md` §3「影片時長（duration_seconds）」，LS-134／135）——拆成獨立
/// 檔案純粹是為了 SwiftLint `file_length`（主檔 `MediaUploadService.swift` 加完 LS-135 這批
/// 改動後逼近 400 行上限），理由同 `InviteFamilyView+ActionBar.swift` 檔頭註解：這裡的成員
/// 不是 `private`（原本在主檔內是 `private static func`，`private` 是以檔案為界，搬到別的
/// 檔案就存取不到 `SupabaseMediaUploadService.uploadVideo` 裡的呼叫點），改用預設（internal）
/// 存取層級，範圍仍只在本 module 內。
extension SupabaseMediaUploadService {
    /// 量測失敗（檔案格式看不懂、`AVAsset` 讀取拋錯）、讀到的時長無效（`!duration.isValid`／
    /// `duration.isIndefinite`）、或秒數 `<= 0` 時一律回傳 `nil`——不阻斷上傳（見 `uploadVideo`
    /// 呼叫端），也不寫 `0`（會撞 `media_duration_seconds_positive` CHECK，此時原檔與縮圖多半
    /// 已經 PUT 完成，INSERT 失敗會留下孤兒物件，見 API.md 同段）。整數秒：`max(1, floor(d))`，
    /// 與 `VideoDurationFormat`／`DiaryDurationFormat` 同源（不足 1 秒的影片記為 1，不進位）。
    static func measureDurationSeconds(
        fileURL: URL, loader: @Sendable (URL) async throws -> CMTime
    ) async -> Int? {
        guard let duration = try? await loader(fileURL), duration.isValid, !duration.isIndefinite else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return max(1, Int(seconds.rounded(.down)))
    }
}

import Foundation

/// `MediaUploadService.softDeleteMedia`（LS-212，見協定檔文件註解）——拆成獨立檔案純粹是為了
/// SwiftLint `file_length`（主檔 `MediaUploadService.swift` 加完這支方法後超過 400 行上限），
/// 理由同 `MediaUploadService+Duration.swift` 檔頭註解：`client`／`now` 因此從 `private` 改成
/// 預設（internal）存取層級，範圍仍只在本 module 內。
extension SupabaseMediaUploadService {
    /// `media_update` policy 對 `authenticated` 是欄位級 grant（`taken_at`／`deleted_at`／
    /// `width`／`height`，`docs/API.md` §3），只更新 `deleted_at` 落在允許範圍內，不需要
    /// 任何 RPC。`now()` 沿用建構時注入的同一個 clock（跟 `uploadPhoto`／`uploadVideo` 共用
    /// 同一個「現在」來源的既有慣例一致，見該欄位文件註解）。
    func softDeleteMedia(mediaIDs: [UUID]) async throws {
        guard !mediaIDs.isEmpty else { return }
        do {
            try await client.from("media")
                .update(["deleted_at": Self.iso8601String(from: now())])
                .in("id", values: mediaIDs)
                .execute()
        } catch {
            throw AppError.map(error)
        }
    }

    /// 明確帶 'Z' 的 ISO8601 字串——同 `SupabaseTimelineAPIClient.iso8601String` 的理由：SDK
    /// 預設 Date 編碼不帶時區指示，Postgres 收到不帶時區的 timestamptz 字面值會依 session
    /// timezone 解讀，不保證是 UTC。
    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

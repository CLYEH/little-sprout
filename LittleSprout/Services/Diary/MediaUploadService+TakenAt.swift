import Foundation

/// LS-304：`media.taken_at`（`supabase/migrations/20260913163828_media_taken_at_hardening.sql`
/// 檔頭「client INSERT／UPDATE 回填」）相關的協定便利多載與編碼工具——從
/// `MediaUploadService.swift` 拆出（SwiftLint `file_length`，理由同
/// `MediaUploadService+SoftDelete.swift`／`MediaUploadService+Duration.swift` 檔頭既有慣例）。
extension MediaUploadService {
    /// 既有呼叫端（日記編輯器單張即傳，`DiaryComposerStore`）不需要指定 `taken_at`——呼叫這個 4-arg
    /// 版本等同 `takenAt: nil`（沿既有行為，`media.taken_at` 留空）。協定要求本身不能帶預設
    /// 參數值（Swift 對 protocol requirement 的限制），這裡用轉呼叫的便利多載補上。
    func uploadPhoto(familyID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
        try await uploadPhoto(
            familyID: familyID, data: data, fileExtension: fileExtension, pixelSize: pixelSize, takenAt: nil
        )
    }

    func uploadVideo(familyID: UUID, fileURL: URL, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
        try await uploadVideo(
            familyID: familyID, fileURL: fileURL, fileExtension: fileExtension, pixelSize: pixelSize, takenAt: nil
        )
    }
}

// `MediaInsertPayload.takenAt` 的編碼（`String?` 不是 `Date?`）重用既有的
// `SupabaseMediaUploadService.iso8601String`（`MediaUploadService+SoftDelete.swift`，
// 該檔這次從 `private` 放寬——同一支型別上不能有兩個同名方法，不重複定義一份）。

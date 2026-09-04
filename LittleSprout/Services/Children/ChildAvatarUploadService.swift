import Foundation
import Supabase

/// 寶貝大頭照上傳（LS-169）。跟 `MediaUploadService` 是兩支獨立協定，不是同一支加參數：
/// 頭像**不寫** `public.media` 表（票文 Scope 1 明講「不寫 media 表、不計額度」——PLAN
/// 額度口徑是 `media` 列，頭像只是 Storage 物件，沒有中繼資料列），路徑形狀也不同
/// （`{family_id}/avatars/{child_id}.jpg`，不是 `{family_id}/{yyyy}/{mm}/{media_id}.{ext}`，
/// 見 `supabase/migrations/20260904060700_avatar_object_path.sql`）——硬套同一支協定只會
/// 讓呼叫端多出一堆對頭像沒有意義的參數（`byteSize`／`pixelSize`／`durationSeconds`…）。
///
/// 回傳值是 Storage **路徑**（不是簽名 URL）——直接對應 `update_child` 的
/// `p_avatar_url`，跟 `public.media.thumb_path` 存路徑、讀取端才簽名的慣例一致（docs/API.md
/// §6「簽名 URL 與 egress 防線」）。
protocol ChildAvatarUploadService: Sendable {
    /// 裁方＋縮圖＋上傳一張大頭照；`imageData` 是 `PhotosPickerItem.loadTransferable` 讀出的
    /// 原始位元組。同一個 `childID` 重複呼叫＝覆蓋既有頭像（換照片走同一個路徑，upsert）。
    /// 回傳可寫進 `update_child(p_avatar_url:)` 的 Storage 路徑。
    func uploadAvatar(familyID: UUID, childID: UUID, imageData: Data) async throws -> String
}

final class SupabaseChildAvatarUploadService: ChildAvatarUploadService {
    private let client: SupabaseClient
    private static let bucketID = "media"
    /// 票文 Scope 1：中心裁方、縮到 512×512 JPEG。
    static let maxPixelSize = 512
    private static let jpegQuality: CGFloat = 0.8

    init(client: SupabaseClient) {
        self.client = client
    }

    func uploadAvatar(familyID: UUID, childID: UUID, imageData: Data) async throws -> String {
        // 票文「不在主執行緒解碼」：這支 service 本身不綁 actor，`uploadAvatar` 由呼叫端
        // （`ChildrenStore`，`@MainActor`）以 `await` 呼叫——把裁方／編碼這段 CPU-bound 工作
        // 丟給 `Task.detached` 的背景執行緒跑，避免佔用呼叫端目前所在的 executor（`@MainActor`）。
        // 同 `PickedItemLoader.downsizedThumbnail` 既有的「呼叫端負責別在主執行緒解碼」慣例，
        // 這裡額外用 `Task.detached` 把責任收進 service 自己（呼叫端不必記得自己開背景 task）。
        let jpegData = try await Task.detached(priority: .userInitiated) {
            AvatarImageProcessor.squareJPEG(from: imageData, maxPixelSize: Self.maxPixelSize, quality: Self.jpegQuality)
        }.value
        guard let jpegData else {
            throw AppError.rejected(message: "這張照片沒辦法使用，請換一張試試", code: nil)
        }
        let path = Self.storagePath(familyID: familyID, childID: childID)
        do {
            try await client.storage.from(Self.bucketID).upload(
                path, data: jpegData,
                options: FileOptions(contentType: "image/jpeg", upsert: true)
            )
        } catch {
            throw AppError.map(error)
        }
        return path
    }

    /// `{family_id}/avatars/{child_id}.jpg`——`family_id`／`child_id` 一律小寫正規形 UUID
    /// （同 `MediaUploadService.storagePath` 的理由：`UUID().uuidString` 預設大寫，
    /// storage.objects 的路徑規約強制小寫，見上述 migration 檔頭）。
    static func storagePath(familyID: UUID, childID: UUID) -> String {
        "\(familyID.uuidString.lowercased())/avatars/\(childID.uuidString.lowercased()).jpg"
    }
}

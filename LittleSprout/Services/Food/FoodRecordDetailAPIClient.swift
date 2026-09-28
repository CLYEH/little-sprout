import Foundation
import Supabase
import SwiftUI

/// 記錄詳情 04（LS-381）額外要讀的兩樣東西——照片（`media_id` → 簽名 URL）與記錄者顯示名稱
/// （`author_id` → `profiles.display_name`）。記錄本身仍走 `FoodAPIClient.listChildFoodRecords`。
///
/// **刻意不併進 `FoodAPIClient`**：第一次記錄 sheet（LS-380）與本票平行實作，LS-380 正在擴充
/// `FoodAPIClient`／`SupabaseFoodAPIClient`／`PreviewFoodAPIClient` 三支檔（寫入 RPC、家庭相簿列表）；
/// 本票另開一支小協定，兩票不改同一個檔、不需要互等。兩票都併入後若要合併成一支，是純機械搬移。
///
/// 方法 ↔ 後端對照（供 `docs/API.md` 對帳）：
///   - `photoURL(mediaID:)`   → SELECT `public.media`（`id`＝`mediaID`，`thumb_path` 優先、`NULL` 退回
///     `storage_path`，同 `TimelineContentAssembler.displayPath` 的 egress 防線）＋ Storage `media` bucket
///     `createSignedURL`（PLAN §8：全私有 bucket，一律簽名 URL）
///   - `displayName(userID:)` → SELECT `public.profiles`（`display_name`；同家庭成員互看，API.md §2）
///
/// 錯誤一律映射為 `AppError`。
protocol FoodRecordDetailAPIClient: Sendable {
    /// `nil`＝這張照片目前看不到（已被軟刪——`media_select` 對非上傳者藏起已刪列——或檔案簽名失敗）。
    func photoURL(mediaID: UUID) async throws -> URL?
    /// `nil`＝查不到（作者已離開家庭，`profiles_select` 只放行同家庭成員）。
    func displayName(userID: UUID) async throws -> String?
}

/// app 根注入（`LittleSproutApp.rootView`）——同 `\.foodAPIClient` 的既有理由（見 `FoodAPIClient.swift`：
/// 入口仍是 DEBUG 暫時入口，不為它改七層導覽型別的 init）。`nil`＝沒注入（harness／preview 由
/// `FoodRecordDetailView` 的 init 參數直接給假 client）。
extension EnvironmentValues {
    @Entry var foodRecordDetailAPIClient: (any FoodRecordDetailAPIClient)?
}

final class SupabaseFoodRecordDetailAPIClient: FoodRecordDetailAPIClient {
    /// 同 `SupabaseTimelineAPIClient.signedURLExpirySeconds`：一次瀏覽階段足夠，重新進入畫面會重簽。
    private static let signedURLExpirySeconds = 3600
    private static let bucket = "media"

    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func photoURL(mediaID: UUID) async throws -> URL? {
        do {
            let response: PostgrestResponse<[FoodRecordMediaPathRow]> = try await client
                .from("media")
                .select("storage_path,thumb_path")
                .eq("id", value: mediaID)
                .limit(1)
                .execute()
            guard let row = response.value.first else { return nil }
            return try await client.storage.from(Self.bucket).createSignedURL(
                path: row.thumbPath ?? row.storagePath, expiresIn: Self.signedURLExpirySeconds
            )
        } catch {
            throw AppError.map(error)
        }
    }

    func displayName(userID: UUID) async throws -> String? {
        do {
            let response: PostgrestResponse<[FoodRecordProfileNameRow]> = try await client
                .from("profiles")
                .select("display_name")
                .eq("id", value: userID)
                .limit(1)
                .execute()
            return response.value.first?.displayName
        } catch {
            throw AppError.map(error)
        }
    }
}

/// `media` 一列裡照片詳情需要的兩欄（`SupabaseFoodRecordDetailAPIClient.photoURL`）。
private struct FoodRecordMediaPathRow: Decodable {
    let storagePath: String
    let thumbPath: String?

    enum CodingKeys: String, CodingKey {
        case storagePath = "storage_path"
        case thumbPath = "thumb_path"
    }
}

/// `profiles.display_name`（`SupabaseFoodRecordDetailAPIClient.displayName`）。
private struct FoodRecordProfileNameRow: Decodable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

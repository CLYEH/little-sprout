import Foundation
import Supabase

/// `FoodAPIClient` 的 Supabase 實作。方法 ↔ 後端對照見協定檔的文件註解。
final class SupabaseFoodAPIClient: FoodAPIClient {
    private let client: SupabaseClient
    /// LS-380「從手機加入」沿既有上傳管線（Storage 原檔＋縮圖 → `media` 列），不另寫一套。預設自建一顆
    /// 無狀態的 `SupabaseMediaUploadService`（同 `LittleSproutApp.mediaUploadService` 的角色），app 根
    /// 注入點（`LittleSproutApp`）不用改。
    private let mediaUploadService: MediaUploadService
    /// PLAN §8：全私有 bucket，一律簽名 URL（同 `SupabaseTimelineAPIClient`）。
    private static let signedURLExpirySeconds = 3600
    private static let bucket = "media"
    private static let photoColumns = "id,storage_path,thumb_path,taken_at,created_at"

    init(client: SupabaseClient, mediaUploadService: MediaUploadService? = nil) {
        self.client = client
        self.mediaUploadService = mediaUploadService ?? SupabaseMediaUploadService(client: client)
    }

    /// 只挑畫面用得到的欄位（不含 `active`）；`active = false` 的品項（日後下架用）不進圖鑑，
    /// 計數句的分母也就不含它們。
    func listFoodCatalog() async throws -> [FoodCatalogItem] {
        do {
            let response: PostgrestResponse<[FoodCatalogItem]> = try await client
                .from("food_catalog")
                .select("id,name_zh,category,sort_order,allergens,min_age_months")
                .eq("active", value: true)
                .order("sort_order", ascending: true)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func listChildFoodRecords(childID: UUID) async throws -> [ChildFoodRecord] {
        do {
            let response: PostgrestResponse<[ChildFoodRecord]> = try await client
                .rpc("list_child_food_records", params: ["p_child_id": childID])
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func upsertChildFoodRecord(_ input: FoodRecordUpsert) async throws -> ChildFoodRecord {
        do {
            let response: PostgrestResponse<ChildFoodRecord> = try await client
                .rpc("upsert_child_food_record", params: UpsertChildFoodRecordParams(input))
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func deleteChildFoodRecord(id: UUID) async throws {
        do {
            try await client.rpc("delete_child_food_record", params: ["p_id": id]).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    func listFamilyPhotos(childID: UUID) async throws -> [FamilyPhoto] {
        do {
            let familyID = try await familyID(ofChild: childID)
            let response: PostgrestResponse<[FamilyPhoto]> = try await client
                .from("media")
                .select(Self.photoColumns)
                .eq("family_id", value: familyID)
                .eq("type", value: "photo")
                .is("deleted_at", value: nil)
                .order("created_at", ascending: false)
                .limit(FamilyPhotoQuery.limit)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func fetchFamilyPhoto(id: UUID) async throws -> FamilyPhoto? {
        do {
            let response: PostgrestResponse<[FamilyPhoto]> = try await client
                .from("media")
                .select(Self.photoColumns)
                .eq("id", value: id)
                .is("deleted_at", value: nil)
                .execute()
            return response.value.first
        } catch {
            throw AppError.map(error)
        }
    }

    /// 單一路徑簽名失敗（例如檔案剛好被硬刪）略過、不讓整批失敗——同
    /// `SupabaseTimelineAPIClient.signedURLs`。
    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] {
        guard !paths.isEmpty else { return [:] }
        do {
            let results = try await client.storage.from(Self.bucket).createSignedURLs(
                paths: paths, expiresIn: Self.signedURLExpirySeconds
            )
            var urlsByPath: [String: URL] = [:]
            for case .success(let path, let signedURL) in results {
                urlsByPath[path] = signedURL
            }
            return urlsByPath
        } catch {
            throw AppError.map(error)
        }
    }

    func uploadPhoto(childID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
        let familyID: UUID
        do {
            familyID = try await self.familyID(ofChild: childID)
        } catch {
            throw AppError.map(error)
        }
        // `uploadPhoto` 自己已把錯誤映射成 `AppError`（`MediaUploadService.mapUploadError`）。
        return try await mediaUploadService.uploadPhoto(
            familyID: familyID, data: data, fileExtension: fileExtension, pixelSize: pixelSize
        )
    }

    /// `media.family_id` 必須與記錄同家庭（`child_food_records` 複合外鍵 `(family_id, media_id)`）——
    /// 以寶貝所屬家庭為準（`children_select` RLS：同家庭成員可讀）。
    private func familyID(ofChild childID: UUID) async throws -> UUID {
        let response: PostgrestResponse<ChildFamilyRow> = try await client
            .from("children")
            .select("family_id")
            .eq("id", value: childID)
            .single()
            .execute()
        return response.value.familyID
    }
}

private struct ChildFamilyRow: Decodable {
    let familyID: UUID

    enum CodingKeys: String, CodingKey {
        case familyID = "family_id"
    }
}

/// `upsert_child_food_record` 的 6 個具名參數在 SQL 端**全部沒有預設值**——同
/// `UpsertGrowthRecordParams` 的既有理由：手動 `encode(to:)`，`nil` 送明確的 JSON `null`，讓 PostgREST
/// 收到全部 6 個 key（省略 key 會找不到函式簽章）。
private struct UpsertChildFoodRecordParams: Encodable {
    let input: FoodRecordUpsert

    init(_ input: FoodRecordUpsert) {
        self.input = input
    }

    enum CodingKeys: String, CodingKey {
        case childID = "p_child_id"
        case foodID = "p_food_id"
        case firstTriedOn = "p_first_tried_on"
        case mediaID = "p_media_id"
        case note = "p_note"
        case reaction = "p_reaction"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input.childID, forKey: .childID)
        try container.encode(input.foodID, forKey: .foodID)
        try container.encode(BirthdayFormat.wireString(from: input.firstTriedOn), forKey: .firstTriedOn)
        try container.encode(input.mediaID, forKey: .mediaID)
        try container.encode(input.note, forKey: .note)
        try container.encode(input.reaction?.rawValue, forKey: .reaction)
    }
}

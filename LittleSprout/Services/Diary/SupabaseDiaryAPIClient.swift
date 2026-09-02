import Foundation
import Supabase

/// `DiaryAPIClient` 的 Supabase 實作。方法 ↔ RPC／資料表對照見協定檔的文件註解。
final class SupabaseDiaryAPIClient: DiaryAPIClient {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func createDiaryEntry(familyID: UUID, body: String, entryDate: Date, childIDs: [UUID]) async throws -> UUID {
        do {
            let params = CreateDiaryEntryParams(
                familyID: familyID,
                childIDs: childIDs,
                body: body,
                entryDate: BirthdayFormat.wireString(from: entryDate)
            )
            let response: PostgrestResponse<UUID> = try await client
                .rpc("create_diary_entry", params: params)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func updateDiaryEntry(diaryID: UUID, body: String, entryDate: Date, childIDs: [UUID]) async throws {
        do {
            let params = UpdateDiaryEntryParams(
                diaryID: diaryID,
                body: body,
                entryDate: BirthdayFormat.wireString(from: entryDate),
                childIDs: childIDs
            )
            try await client.rpc("update_diary_entry", params: params).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    /// `diary_media` 不是 RPC-only（見 `docs/API.md` §2「寫入路徑小結」）——owner／member
    /// 可直接寫，`sort_order` 用陣列 index 表達佇列順序。
    ///
    /// 用 `upsert` 而不是 `insert`（merge-review R2 n1）：PK 是 `(diary_id, media_id)`
    /// （`20260822120000_init_schema.sql`）。`DiaryComposerStore` 的續傳保護保證重試一定
    /// 用同一個 `diaryID`／同一批 media id 呼叫這裡——若上一次其實已經寫入成功、只是回應在
    /// 網路上遺失（client 因此誤判失敗），純 `insert` 重試會撞主鍵拿 `23505`，變成永遠發不
    /// 出去的死路。
    ///
    /// `ignoreDuplicates: false`（`resolution=merge-duplicates` → `ON CONFLICT DO UPDATE`；
    /// merge-review R3 P1，修正 R2 n1 引入的缺陷）：`mediaIDs` 的順序跟著使用者當下的佇列
    /// 順序走，`sort_order` 是這裡依 `enumerated()` 現算的——若上一輪失敗前伺服器端其實已
    /// commit、使用者在重試前又拖曳重排／新增照片，`true`（`DO NOTHING`）會讓衝突列的
    /// `sort_order` 完全不更新，DB 留著舊順序卻回報成功（靜默錯誤資料，比撞 `23505` 更難
    /// 察覺）。`false` 讓衝突列的 `sort_order` 隨新內容更新，同時仍然不會撞 `23505`。
    /// **已知殘餘**：這條路徑上只有 `INSERT`／`UPDATE`，沒有 `DELETE`——若使用者在同一個
    /// 窗把某張照片移出佇列再重試，該照片的 `diary_media` 列不會被刪（記入 LS-96
    /// `d8634a08-e92a-4bce-9f14-72de01f9b67a`）。
    func attachMedia(diaryID: UUID, familyID: UUID, mediaIDs: [UUID]) async throws {
        guard !mediaIDs.isEmpty else { return }
        do {
            let rows = mediaIDs.enumerated().map { index, mediaID in
                DiaryMediaRow(diaryID: diaryID, mediaID: mediaID, familyID: familyID, sortOrder: index)
            }
            try await client.from("diary_media")
                .upsert(rows, onConflict: "diary_id,media_id", ignoreDuplicates: false)
                .execute()
        } catch {
            throw AppError.map(error)
        }
    }
}

// MARK: - Wire payloads

private struct CreateDiaryEntryParams: Encodable {
    let familyID: UUID
    let childIDs: [UUID]
    let body: String
    let entryDate: String

    enum CodingKeys: String, CodingKey {
        case familyID = "p_family_id"
        case childIDs = "p_child_ids"
        case body = "p_body"
        case entryDate = "p_entry_date"
    }
}

private struct UpdateDiaryEntryParams: Encodable {
    let diaryID: UUID
    let body: String
    let entryDate: String
    let childIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case diaryID = "p_diary_id"
        case body = "p_body"
        case entryDate = "p_entry_date"
        case childIDs = "p_child_ids"
    }
}

private struct DiaryMediaRow: Encodable {
    let diaryID: UUID
    let mediaID: UUID
    let familyID: UUID
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case diaryID = "diary_id"
        case mediaID = "media_id"
        case familyID = "family_id"
        case sortOrder = "sort_order"
    }
}

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
    /// 可直接 `.insert()`，`sort_order` 用陣列 index 表達佇列順序。
    func attachMedia(diaryID: UUID, familyID: UUID, mediaIDs: [UUID]) async throws {
        guard !mediaIDs.isEmpty else { return }
        do {
            let rows = mediaIDs.enumerated().map { index, mediaID in
                DiaryMediaRow(diaryID: diaryID, mediaID: mediaID, familyID: familyID, sortOrder: index)
            }
            try await client.from("diary_media").insert(rows).execute()
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

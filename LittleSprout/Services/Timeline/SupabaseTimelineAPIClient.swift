import Foundation
import Supabase

/// `TimelineAPIClient` 的 Supabase 實作。方法 ↔ RPC／資料表對照見協定檔的文件註解。
final class SupabaseTimelineAPIClient: TimelineAPIClient {
    /// PLAN §8：全私有 bucket，一律簽名 URL；1 小時足夠一次時間軸瀏覽階段使用，
    /// 過期後下拉更新／重新進入畫面會拿到新的一批。
    private static let signedURLExpirySeconds = 3600
    private static let bucket = "media"

    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func fetchTimelinePointers(
        familyID: UUID, childID: UUID?, cursor: TimelineCursor?, limit: Int
    ) async throws -> [TimelineFeedPointer] {
        do {
            let params = TimelineParams(
                familyID: familyID,
                childID: childID,
                cursorOccurredAt: cursor.map { Self.iso8601String(from: $0.occurredAt) },
                cursorRefID: cursor?.refId,
                limit: limit
            )
            let response: PostgrestResponse<[TimelineFeedPointer]> = try await client
                .rpc("get_family_timeline", params: params)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func fetchDiaries(ids: [UUID]) async throws -> [DiaryRow] {
        guard !ids.isEmpty else { return [] }
        do {
            let response: PostgrestResponse<[DiaryRow]> = try await client
                .from("diaries")
                .select()
                .in("id", values: ids)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func fetchDiaryMediaLinks(diaryIds: [UUID]) async throws -> [DiaryMediaLinkRow] {
        guard !diaryIds.isEmpty else { return [] }
        do {
            let response: PostgrestResponse<[DiaryMediaLinkRow]> = try await client
                .from("diary_media")
                .select()
                .in("diary_id", values: diaryIds)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func fetchAlbums(ids: [UUID]) async throws -> [AlbumRow] {
        guard !ids.isEmpty else { return [] }
        do {
            let response: PostgrestResponse<[AlbumRow]> = try await client
                .from("albums")
                .select()
                .in("id", values: ids)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func fetchMedia(ids: [UUID]) async throws -> [MediaRow] {
        guard !ids.isEmpty else { return [] }
        do {
            let response: PostgrestResponse<[MediaRow]> = try await client
                .from("media")
                .select()
                .in("id", values: ids)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] {
        guard !paths.isEmpty else { return [:] }
        do {
            let results = try await client.storage.from(Self.bucket).createSignedURLs(
                paths: paths, expiresIn: Self.signedURLExpirySeconds
            )
            var urlsByPath: [String: URL] = [:]
            for result in results {
                switch result {
                case .success(let path, let signedURL):
                    urlsByPath[path] = signedURL
                case .failure:
                    // 單一路徑簽名失敗（例如檔案剛好被硬刪）：略過，不讓整批失敗——
                    // 見協定檔 `signedURLs` 文件註解。
                    continue
                }
            }
            return urlsByPath
        } catch {
            throw AppError.map(error)
        }
    }

    /// 明確帶 'Z' 的 ISO8601 字串——同 `SupabaseFamilyAPIClient.iso8601String` 的理由：
    /// SDK 預設 Date 編碼不帶時區指示，Postgres 收到不帶時區的 timestamptz 字面值會依
    /// session timezone 解讀，不保證是 UTC。
    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// `get_family_timeline` 的 5 個具名參數皆有 SQL 預設值（`docs/API.md`）——不同於
/// `create_child`／`update_child` 的 `p_avatar_url`（那支沒有 SQL 預設值，見
/// `SupabaseChildAPIClient` 文件註解），這裡可以放心用預設合成的 `Encodable`：
/// `Optional` 屬性為 nil 時會用 `encodeIfPresent` 整個省略該 key，PostgREST 遇到具名
/// 呼叫缺了某個有預設值的參數時就直接套用 SQL 預設，語意正確、不需要手動送明確 `null`。
private struct TimelineParams: Encodable {
    let familyID: UUID
    let childID: UUID?
    /// 明確帶時區的 ISO8601 字串（見 `SupabaseTimelineAPIClient.iso8601String`），不是
    /// 原生 `Date`——理由同該方法文件註解。
    let cursorOccurredAt: String?
    let cursorRefID: UUID?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case familyID = "p_family_id"
        case childID = "p_child_id"
        case cursorOccurredAt = "p_cursor_occurred_at"
        case cursorRefID = "p_cursor_ref_id"
        case limit = "p_limit"
    }
}

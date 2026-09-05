import Foundation
import Supabase

/// `AlbumsAPIClient` 的 Supabase 實作。方法 ↔ RPC／資料表對照見協定檔的文件註解。
final class SupabaseAlbumsAPIClient: AlbumsAPIClient {
    /// 同 `SupabaseTimelineAPIClient.signedURLExpirySeconds`——PLAN §8 全私有 bucket，一律
    /// 簽名 URL，1 小時足夠一次相簿列表瀏覽階段使用。
    private static let signedURLExpirySeconds = 3600
    private static let bucket = "media"

    /// 張數（PostgREST aggregate，本機已實測 `db-aggregates-enabled` 可用）＋封面 fallback
    /// 一次內嵌查出（merge-review R1 M1）：
    ///   - `album_media(count)` → `AlbumListingRow.photoCount`（見該型別文件註解）。
    ///   - `latest:album_media(media(...))`，靠下方 `.order(referencedTable: "latest")`／
    ///     `.limit(referencedTable: "latest")` 依 `media(created_at)` 取最新一筆
    ///     → `AlbumListingRow.latestMediaThumbPath`／`latestMediaStoragePath`。
    /// 兩個內嵌都叫 `album_media` 但用不同別名（`latest:`）——PostgREST 對同一張表嵌兩次時，
    /// 排序／筆數限制修飾詞（`?xxx.order=`／`?xxx.limit=`）要用別名而非表名當前綴，否則會拿到
    /// `PGRST108`（本機實測撞過）。`media(created_at)` 必須同時出現在這個內嵌的 select 欄位
    /// 清單裡（即使組裝端用不到這個值）——只用來排序、不選進 select 會拿到 `42703`
    /// column does not exist（本機實測撞過，PostgREST 排序時似乎是對 select 出來的欄位做
    /// 二次查找，不是任意可存取欄位都能直接拿來排序）。
    private static let listSelect =
        "id,title,cover_media_id,created_at,album_media(count)," +
        "latest:album_media(media(thumb_path,storage_path,created_at))"

    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func fetchAlbums(familyID: UUID, cursor: AlbumsCursor?, limit: Int) async throws -> [AlbumListingRow] {
        do {
            var query = client
                .from("albums")
                .select(Self.listSelect)
                .eq("family_id", value: familyID)
                .is("deleted_at", value: nil)
            if let cursor {
                // keyset 分頁：`created_at < cursor` 或（同一時間戳時）`id < cursor.id`——
                // 同 `TimelineCursor` 一對值的理由，避免同一秒建立多本相簿時漏項／跳項。
                let createdAtValue = Self.iso8601String(from: cursor.createdAt)
                query = query.or(
                    "created_at.lt.\(createdAtValue),and(created_at.eq.\(createdAtValue),id.lt.\(cursor.id.uuidString))"
                )
            }
            let response: PostgrestResponse<[AlbumListingRow]> = try await query
                .order("media(created_at)", ascending: false, referencedTable: "latest")
                .limit(1, referencedTable: "latest")
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .limit(limit)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func fetchAlbumChildren(albumIds: [UUID]) async throws -> [AlbumChildLinkRow] {
        guard !albumIds.isEmpty else { return [] }
        do {
            let response: PostgrestResponse<[AlbumChildLinkRow]> = try await client
                .from("album_children")
                .select("album_id,child_id")
                .in("album_id", values: albumIds)
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
                    // 單一路徑簽名失敗（例如檔案剛好被硬刪）：略過，不讓整批失敗——見協定檔
                    // `signedURLs` 文件註解。
                    continue
                }
            }
            return urlsByPath
        } catch {
            throw AppError.map(error)
        }
    }

    func createAlbum(familyID: UUID, title: String) async throws -> AlbumListingRow {
        do {
            // albums_insert 的 RLS WITH CHECK 要求 created_by = auth.uid()（docs/API.md §2
            // `albums` 列）——同 `SupabaseFamilyAPIClient.createFamily` 既有寫法，用
            // `client.auth.session`（async 版本，過期時會先嘗試刷新）而不是同步的
            // `currentSession`。這裡不需要另外呼叫 `ensureProfileExists`：呼叫端已經有家庭
            // （`familyID` 由 `FamilyStore.myFamily` 提供），代表這個帳號在建立／加入家庭時
            // 就已經補過 `profiles` 列。
            let session = try await client.auth.session
            let payload = CreateAlbumPayload(familyID: familyID, title: title, createdBy: session.user.id)
            // 剛建立的相簿必定 0 張照片（`album_media` 還沒有任何連結列）——用跟 `fetchAlbums`
            // 同一份 `Self.listSelect`，讓 `AlbumListingRow.init(from:)` 吃到的巢狀陣列形狀
            // 一致（`album_media: [{"count": 0}]`／`latest: []`），不需要另外維護一份簡化版
            // select 字串。
            let response: PostgrestResponse<AlbumListingRow> = try await client
                .from("albums")
                .insert(payload)
                .select(Self.listSelect)
                .single()
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func setAlbumChildren(albumID: UUID, childIDs: [UUID]) async throws {
        do {
            let params = SetAlbumChildrenParams(albumID: albumID, childIDs: childIDs)
            try await client.rpc("set_album_children", params: params).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    func setAlbumDeleted(albumID: UUID, deleted: Bool) async throws {
        do {
            let params = SetAlbumDeletedParams(albumID: albumID, deleted: deleted)
            try await client.rpc("set_album_deleted", params: params).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    /// 明確帶 'Z' 的 ISO8601 字串——同 `SupabaseTimelineAPIClient.iso8601String` 的理由：SDK
    /// 預設 Date 編碼不帶時區指示，Postgres 收到不帶時區的 timestamptz 字面值會依 session
    /// timezone 解讀，不保證是 UTC。不用 `Date.rawValue`（`PostgrestFilterValue` 協定）：
    /// `Realtime` 與 `PostgREST` 兩個模組都對 `Date` extension 出同名 `rawValue`，直接呼叫在
    /// 這個 target 的 import 組合下是 `ambiguous use of 'rawValue'`（實測編譯錯誤），改自己
    /// 格式化字串繞開。
    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct CreateAlbumPayload: Encodable {
    let familyID: UUID
    let title: String
    let createdBy: UUID

    enum CodingKeys: String, CodingKey {
        case familyID = "family_id"
        case title
        case createdBy = "created_by"
    }
}

private struct SetAlbumChildrenParams: Encodable {
    let albumID: UUID
    let childIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case albumID = "p_album_id"
        case childIDs = "p_child_ids"
    }
}

private struct SetAlbumDeletedParams: Encodable {
    let albumID: UUID
    let deleted: Bool

    enum CodingKeys: String, CodingKey {
        case albumID = "p_album_id"
        case deleted = "p_deleted"
    }
}

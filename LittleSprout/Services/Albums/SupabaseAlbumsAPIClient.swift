import Foundation
import Supabase

/// `AlbumsAPIClient` 的 Supabase 實作。方法 ↔ RPC／資料表對照見協定檔的文件註解。
final class SupabaseAlbumsAPIClient: AlbumsAPIClient {
    /// 同 `SupabaseTimelineAPIClient.signedURLExpirySeconds`——PLAN §8 全私有 bucket，一律
    /// 簽名 URL，1 小時足夠一次相簿列表瀏覽階段使用。
    private static let signedURLExpirySeconds = 3600
    private static let bucket = "media"

    /// `album_summaries`（LS-200 security-invoker view）欄位子集——LS-203 起改讀這支 view，
    /// 不再用 PostgREST 內嵌 aggregate／embed 查詢在 client 端組裝（LS-165 R1–R3 遺留的
    /// `album_media(count)` 連結列計數口徑差異、`latest:album_media(media!inner(...))`
    /// 內嵌 null 安全等問題，`album_summaries` 已經在 SQL 層一次算完，見該 view 定義檔
    /// `supabase/migrations/20260905074037_album_summaries_view.sql` 與 `AlbumListingRow`
    /// 文件註解）。`view` 不可寫，`createAlbum` 的 INSERT 仍要走 `albums` 本身（見下）。
    private static let listSelect =
        "id,title,created_at,visible_media_count,latest_media_id,latest_thumb_path," +
        "latest_storage_path,cover_thumb_path,cover_storage_path"

    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func fetchAlbums(familyID: UUID, cursor: AlbumsCursor?, limit: Int) async throws -> [AlbumListingRow] {
        do {
            var query = client
                .from("album_summaries")
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
            // `album_summaries` 是唯讀 view（沒有 INSERT grant），INSERT 一律走 `albums`
            // 本身——這裡只取 `id` 供下一步重讀用（票文 Scope 3）。
            let inserted: PostgrestResponse<CreatedAlbumIDRow> = try await client
                .from("albums")
                .insert(payload)
                .select("id")
                .single()
                .execute()
            // 插入後以 view 重讀剛建立的這一列，取得跟 `fetchAlbums` 一致的摘要形狀——剛建立
            // 的相簿必定 0 張照片、沒有封面，重讀一次比在這裡手動組一份「猜」出來的
            // `AlbumListingRow` 更穩：不必自己重複 view 的 `coalesce`／fallback 邏輯，未來
            // view 欄位若調整也不會有兩份邏輯各自漂移，也不會有新建相簿短暫顯示錯誤張數的空窗。
            let response: PostgrestResponse<AlbumListingRow> = try await client
                .from("album_summaries")
                .select(Self.listSelect)
                .eq("id", value: inserted.value.id)
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

    // MARK: - LS-166（相簿詳情）

    func fetchAlbumMediaLinks(albumID: UUID) async throws -> [AlbumMediaLinkRow] {
        do {
            let response: PostgrestResponse<[AlbumMediaLinkRow]> = try await client
                .from("album_media")
                .select("album_id,media_id,sort_order")
                .eq("album_id", value: albumID)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func attachMedia(albumID: UUID, familyID: UUID, mediaID: UUID, sortOrder: Int) async throws {
        do {
            let row = AttachAlbumMediaPayload(
                albumID: albumID, mediaID: mediaID, familyID: familyID, sortOrder: sortOrder
            )
            try await client.from("album_media")
                .upsert(row, onConflict: "album_id,media_id", ignoreDuplicates: false)
                .execute()
        } catch {
            throw AppError.map(error)
        }
    }

    func updateAlbumTitle(albumID: UUID, title: String) async throws {
        do {
            try await requireUpdatedRow(
                client.from("albums")
                    .update(UpdateAlbumTitlePayload(title: title))
                    .eq("id", value: albumID)
            )
        } catch {
            throw AppError.map(error)
        }
    }

    /// merge-review R2 M1：`albums_update` policy 是 USING 過濾（不是 WITH CHECK 擋 INSERT
    /// 那種硬性拒絕）——owner 對別人建立的相簿下 `.update()` 內容欄位時，那一列不在 USING
    /// 比對得到的範圍內，UPDATE 語句本身合法執行，只是匹配 0 列，PostgREST 回 200 + `[]`，
    /// SDK 端完全不會 throw（`docs/API.md` §2「靜默 0 列」例外，`albums.title`／
    /// `cover_media_id` 適用）。同 `SupabaseFamilyAPIClient.requireUpdatedRow`
    /// （`families_update` 一樣是 USING 過濾）同一組理由，這裡不重複貼一遍——不擋這個情況的話，
    /// UI 會顯示「已儲存」但伺服器其實什麼都沒改。這裡把「0 列受影響」明確轉成錯誤（`.update()`
    /// 預設 `returning: .representation`，不需要另外呼叫 `.select()` 才能拿到受影響列）。
    private func requireUpdatedRow(_ builder: PostgrestFilterBuilder) async throws {
        let response: PostgrestResponse<[AlbumIDRow]> = try await builder.execute()
        guard !response.value.isEmpty else {
            throw AppError.rejected(message: "沒有權限修改這本相簿，或相簿不存在", code: "no_rows_updated")
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

/// `createAlbum` INSERT 步驟只需要拿回新列的 id，供第二步向 `album_summaries` 重讀用——不
/// 借用 `AlbumListingRow`（那支對映的是 view 的欄位形狀，`albums` 表的 INSERT 回應不會有
/// `visible_media_count` 等彙總欄）。
private struct CreatedAlbumIDRow: Decodable {
    let id: UUID
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

private struct AttachAlbumMediaPayload: Encodable {
    let albumID: UUID
    let mediaID: UUID
    let familyID: UUID
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case albumID = "album_id"
        case mediaID = "media_id"
        case familyID = "family_id"
        case sortOrder = "sort_order"
    }
}

private struct UpdateAlbumTitlePayload: Encodable {
    let title: String
}

/// `requireUpdatedRow` 的解碼目標——只需要知道「有沒有列」，不需要完整 `albums` 欄位（`Decodable`
/// 對多出來的欄位本來就會忽略，不需要宣告完整欄位才能解碼成功）。
private struct AlbumIDRow: Decodable {
    let id: UUID
}

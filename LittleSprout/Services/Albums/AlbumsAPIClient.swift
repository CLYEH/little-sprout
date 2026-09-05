import Foundation

/// 相簿 tab 首頁（LS-165）的型別化 client 介面。
///
/// 方法 ↔ RPC／資料表對照（供 `docs/API.md` 對帳）：
///   - `fetchAlbums`        → SELECT `public.albums`（`family_id` 篩選＋`deleted_at is null`，
///                            `created_at desc, id desc` 排序＋keyset 游標；內嵌
///                            `album_media(count)` 與 `latest:album_media(media(...))`，
///                            見 `AlbumListingRow` 文件註解與 `SupabaseAlbumsAPIClient.
///                            fetchAlbums` 實作——沒有專屬的 `list_albums` RPC）
///   - `fetchAlbumChildren`   → SELECT `public.album_children`（`.in("album_id", ids)`）
///   - `fetchMedia`           → SELECT `public.media`（`.in("id", ids)`，重用
///                              `TimelineModels.MediaRow`）
///   - `signedURLs`           → Storage `media` bucket `createSignedURLs`（同
///                              `TimelineAPIClient.signedURLs`，各自獨立宣告：本專案慣例是
///                              每個 feature 自己的 API client 協定各自完整，不共用跨 feature
///                              的協定，見 `ChildAPIClient`／`DiaryAPIClient`／
///                              `TimelineAPIClient` 既有先例）
///   - `createAlbum`          → INSERT `public.albums`（owner／member，`created_by` 必須是
///                              自己，見 docs/API.md §2 `albums` 列）
///   - `setAlbumChildren`     → RPC `set_album_children(p_album_id, p_child_ids)`
///   - `setAlbumDeleted`      → RPC `set_album_deleted(p_album_id, p_deleted)`——目前唯一
///                              呼叫端是 `AlbumsStore.createAlbum` 的補償路徑（merge-review R1
///                              M2）：`createAlbum` 成功但 `setAlbumChildren` 失敗時，軟刪剛
///                              建立的相簿，避免留下一本標記不到寶貝、卻仍出現在列表的孤兒相簿。
///
/// 錯誤一律映射為 `AppError`，不直接往外拋 PostgREST 的 error 型別。
protocol AlbumsAPIClient: Sendable {
    /// 一頁相簿（`family_id` 篩選、已軟刪除的不回傳）。`cursor` 為 nil＝第一頁。張數與封面
    /// fallback 已內嵌在 `AlbumListingRow`，不需要另一支方法查 `album_media`。
    func fetchAlbums(familyID: UUID, cursor: AlbumsCursor?, limit: Int) async throws -> [AlbumListingRow]

    func fetchAlbumChildren(albumIds: [UUID]) async throws -> [AlbumChildLinkRow]
    func fetchMedia(ids: [UUID]) async throws -> [MediaRow]

    /// 批次簽名——回傳 `[storage_path: URL]`；單一路徑簽名失敗時該路徑不會出現在字典裡（同
    /// `TimelineAPIClient.signedURLs` 文件註解）。
    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL]

    /// 建立一本新相簿（「新增相簿」sheet，票文 Scope 2）——`created_by` 由呼叫端內部帶入目前
    /// session 的 user id（同 `FamilyAPIClient.createFamily` 既有寫法），不需要呼叫端傳入。
    func createAlbum(familyID: UUID, title: String) async throws -> AlbumListingRow

    /// 設定新相簿的寶貝標記（全覆蓋語意，見 docs/API.md §4 `set_album_children`）。
    /// `childIDs` 為空陣列＝不標記任何寶貝。
    func setAlbumChildren(albumID: UUID, childIDs: [UUID]) async throws

    /// 軟刪／還原（見 docs/API.md §4 `set_album_deleted`）——`AlbumsStore.createAlbum` 補償
    /// 路徑專用（見協定檔文件註解），本票不提供還原／刪除相簿的使用者入口（LS-166 範圍）。
    func setAlbumDeleted(albumID: UUID, deleted: Bool) async throws
}

import Foundation

/// 相簿 tab 首頁（LS-165）的型別化 client 介面。
///
/// 方法 ↔ RPC／資料表對照（供 `docs/API.md` 對帳）：
///   - `fetchAlbums`        → SELECT `public.albums`（`family_id` 篩選＋`deleted_at is null`，
///                            `created_at desc, id desc` 排序＋keyset 游標；沒有專屬的
///                            `list_albums` RPC，見 §2 `albums` 列「沒有 list_albums 這類新
///                            RPC 要建」）
///   - `fetchAlbumMediaLinks` → SELECT `public.album_media`（`.in("album_id", ids)`）
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
///
/// 錯誤一律映射為 `AppError`，不直接往外拋 PostgREST 的 error 型別。
protocol AlbumsAPIClient: Sendable {
    /// 一頁相簿（`family_id` 篩選、已軟刪除的不回傳）。`cursor` 為 nil＝第一頁。
    func fetchAlbums(familyID: UUID, cursor: AlbumsCursor?, limit: Int) async throws -> [AlbumListingRow]

    func fetchAlbumMediaLinks(albumIds: [UUID]) async throws -> [AlbumMediaLinkRow]
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
}

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

    /// 軟刪／還原（見 docs/API.md §4 `set_album_deleted`）——LS-165 只用於 `AlbumsStore
    /// .createAlbum` 補償路徑；LS-166 起也是相簿詳情「刪除相簿」的使用者入口（owner 限定，
    /// 見 `AlbumDetailView`）。
    func setAlbumDeleted(albumID: UUID, deleted: Bool) async throws

    // MARK: - LS-166（相簿詳情）

    /// 一本相簿目前的全部 `album_media` 連結列（不分頁——票文壓測上限 34 張，一次抓齊）。
    func fetchAlbumMediaLinks(albumID: UUID) async throws -> [AlbumMediaLinkRow]

    /// 「加入照片」上傳成功後把新 `media` 列掛進這本相簿——直接 `.insert()`（`album_media`
    /// 對 owner／member 開 INSERT grant，不是 RPC-only，見 docs/API.md §2），同
    /// `DiaryAPIClient.attachMedia` 對 `diary_media` 的既有寫法（`upsert`＋`onConflict`，
    /// 避免同一張照片被同一個呼叫端意外重複掛兩次時撞 `(album_id, media_id)` 主鍵衝突）。
    /// `sortOrder` 由呼叫端算好傳入（`AlbumDetailStore` 依目前已知連結數遞增），這裡不重新查
    /// 一次目前最大值——見該 store 文件註解。
    func attachMedia(albumID: UUID, familyID: UUID, mediaID: UUID, sortOrder: Int) async throws

    /// 編輯相簿名稱——`albums.title` 僅建立者本人可直接 `.update()`（`albums_update` policy，
    /// docs/API.md §2 `albums` 列），owner 對別人建立的相簿沒有這條路徑（`AlbumDetailView`
    /// 因此把「更多」選單整體限定 owner 可見，不細分「owner 改自己的」與「owner 改別人的」
    /// 這種 policy 不允許的情境）。
    func updateAlbumTitle(albumID: UUID, title: String) async throws
}

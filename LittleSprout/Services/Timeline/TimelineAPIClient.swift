import Foundation

/// 時間軸（LS-126）的型別化 client 介面。
///
/// 方法 ↔ RPC／資料表對照（供 `docs/API.md` 對帳）：
///   - `fetchTimelinePointers`  → RPC `get_family_timeline(p_family_id, p_child_id,
///                                p_cursor_occurred_at, p_cursor_ref_id, p_limit)`
///   - `fetchDiaries`           → SELECT `public.diaries`（`.in("id", ids)`）
///   - `fetchDiaryMediaLinks`   → SELECT `public.diary_media`（`.in("diary_id", ids)`）
///   - `fetchAlbums`            → SELECT `public.albums`（`.in("id", ids)`）
///   - `fetchMedia`             → SELECT `public.media`（`.in("id", ids)`）
///   - `signedURLs`             → Storage `media` bucket `createSignedURLs`（PLAN §8：
///                                全私有 bucket，一律簽名 URL，不組公開網址）
///
/// 錯誤一律映射為 `AppError`（`fetchTimelinePointers`／`fetchDiaries`／`fetchAlbums`／
/// `fetchMedia`／`fetchDiaryMediaLinks`），不直接往外拋 PostgREST 的 error 型別。
/// `signedURLs` 對單一路徑簽名失敗時**不**整批失敗（見該方法文件）。
protocol TimelineAPIClient: Sendable {
    /// 一頁時間軸指標（`kind`／`ref_id`）——不是完整內容，見 `TimelineContentAssembler`。
    /// `cursor` 為 nil＝第一頁；`childID` 為 nil＝不篩（`media` 類項目在 `childID` 非 nil
    /// 時恆不出現，見 docs/API.md，這是後端既有裁量，不是呼叫端要處理的邊界）。
    func fetchTimelinePointers(
        familyID: UUID, childID: UUID?, cursor: TimelineCursor?, limit: Int
    ) async throws -> [TimelineFeedPointer]

    func fetchDiaries(ids: [UUID]) async throws -> [DiaryRow]
    func fetchDiaryMediaLinks(diaryIds: [UUID]) async throws -> [DiaryMediaLinkRow]
    func fetchAlbums(ids: [UUID]) async throws -> [AlbumRow]
    func fetchMedia(ids: [UUID]) async throws -> [MediaRow]

    /// 批次簽名——回傳 `[storage_path: URL]`；單一路徑簽名失敗時該路徑不會出現在字典裡
    /// （呼叫端顯示占位圖，不因為一張照片壞掉讓整頁組裝失敗）。空陣列直接回傳空字典，
    /// 不發請求。
    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL]
}

import Foundation

/// 日記本體（LS-21／LS-48／LS-121）的型別化 client 介面。
///
/// 方法 ↔ RPC／資料表對照（供 `docs/API.md` §4／§8 對帳）：
///   - `createDiaryEntry` → RPC `create_diary_entry(p_family_id, p_child_ids, p_body, p_entry_date)`
///   - `updateDiaryEntry` → RPC `update_diary_entry(p_diary_id, p_body, p_entry_date, p_child_ids)`
///   - `attachMedia`      → INSERT `public.diary_media`（owner／member 皆可直接寫，見 §2
///                          `diary_media` 列；非 RPC，因為這張表沒有收斂成 RPC-only）
///
/// 錯誤一律映射為 `AppError`（見該檔），不直接往外拋 PostgREST 的 error 型別。
protocol DiaryAPIClient: Sendable {
    /// 建立一篇新日記；該家庭 owner／member 皆可呼叫。回傳新建列的 id。`childIDs` 空陣列＝
    /// 不指定任何寶貝（家庭共用）。
    func createDiaryEntry(familyID: UUID, body: String, entryDate: Date, childIDs: [UUID]) async throws -> UUID

    /// PUT 語意整組替換 `body`／`entryDate`／`childIDs`；只有原作者本人、且仍是該家庭
    /// owner/member 才能成功（見 `docs/API.md` §4）。目前唯一呼叫端是
    /// `DiaryComposerStore.resolveDiaryID` 的重試路徑（送出失敗後使用者改過內容再試一次，
    /// merge-review R2 N1）——「編輯一篇已發佈日記」這種獨立 UI 入口（時間軸／詳情畫面）
    /// 還沒有。
    func updateDiaryEntry(diaryID: UUID, body: String, entryDate: Date, childIDs: [UUID]) async throws

    /// 把已上傳的 `media` 列依陣列順序掛到一篇日記底下（`sort_order` = 陣列 index）。
    /// `mediaIDs` 為空時是合法的 no-op（沒有照片的純文字日記）。
    func attachMedia(diaryID: UUID, familyID: UUID, mediaIDs: [UUID]) async throws
}

import Foundation

/// 檢舉／封鎖／Owner 移除內容（LS-149 後端、LS-189 這裡是第一個 iOS 消費端）的型別化 client
/// 介面。
///
/// 方法 ↔ RPC／資料表對照（供 `docs/API.md` §4／§3 對帳）：
///   - `fetchContentAuthor` → 直接讀 `diaries.author_id`／`albums.created_by`／
///     `media.uploaded_by`／`comments.author_id`（皆為家庭成員可讀欄位，見 §2／§3；不是新 RPC）
///   - `reportContent` → RPC `report_content(p_family_id, p_target_type, p_target_id, p_reason)`
///   - `blockUser` → RPC `block_user(p_family_id, p_blocked_id)`
///   - `unblockUser` → RPC `unblock_user(p_family_id, p_blocked_id)`
///   - `removeContentAsOwner` → RPC `remove_content_as_owner(p_target_type, p_target_id)`
///   - `listBlockedUsers` → 直接讀 `blocked_users`（RLS：`blocker_id = 我`）
///   - `listPendingReports` → 直接讀 `content_reports`（RLS：owner 讀得到自家全部；§3）
///   - `markReportResolved` → 直接 `UPDATE content_reports SET status = 'resolved'`
///     （§3：「僅 status 欄，owner-only，且只能改成 resolved」，不是 RPC）
///   - `fetchReportSnippet` → 直接讀對應表的內容欄位（`diaries.body`／`comments.body`／
///     `albums.title`；`media` 沒有文字內容，回傳 nil）
///
/// 錯誤一律映射為 `AppError`，不直接往外拋 PostgREST 的 error 型別（同 `CommentAPIClient` 既有
/// 慣例）。
protocol SafetyAPIClient: Sendable {
    func fetchContentAuthor(targetType: ContentTargetType, targetID: UUID) async throws -> UUID?
    func reportContent(
        familyID: UUID, targetType: ContentTargetType, targetID: UUID, reason: ReportReason
    ) async throws
    func blockUser(familyID: UUID, blockedID: UUID) async throws
    func unblockUser(familyID: UUID, blockedID: UUID) async throws
    func removeContentAsOwner(targetType: ContentTargetType, targetID: UUID) async throws
    func listBlockedUsers(familyID: UUID) async throws -> [BlockedUserRecord]
    /// Owner 限定（`docs/API.md` §3 `content_reports` 段）——非 owner 呼叫會因為 RLS 只拿到
    /// 「自己送出的」那一部分，不是錯誤，只是清單較短；`ReportInboxView` 本身只掛在 Owner 才
    /// 顯示的 `SettingsContentSafetyComposition.rows(isOwner:)` 入口後面（LS-188 既有慣例），
    /// 這支方法不重複做角色檢查。
    func listPendingReports(familyID: UUID) async throws -> [ContentReportRecord]
    func markReportResolved(reportID: UUID) async throws
    func fetchReportSnippet(targetType: ContentTargetType, targetID: UUID) async throws -> String?
}

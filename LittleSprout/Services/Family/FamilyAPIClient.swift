import Foundation

/// 家庭／邀請／加入審核的型別化 client 介面。
///
/// 方法 ↔ RPC／資料表對照（供 LS-41 docs/API.md 對帳）：
///   - `createFamily`         → INSERT `public.families`（`private.add_creator_as_owner` trigger
///                              把建立者寫成第一位 owner；沒有對應 RPC，走 REST + RLS）
///   - `fetchMyFamily`        → SELECT `public.families`（`families_select` policy的
///                              `id in (private.family_ids())` 分支自然把結果收斂到呼叫者所屬
///                              的家庭；LS-107，Phase 1 單一家庭 MVP 只取第一筆）
///   - `updateFamilyName`     → UPDATE `public.families` (name)
///   - `setRequireApproval`   → UPDATE `public.families` (require_approval)
///   - `createInvite`         → RPC `create_invite(p_family_id, p_role, p_expires_at, p_max_uses)`
///   - `requestJoin`          → RPC `request_join(p_code)`
///   - `approveJoin`          → RPC `approve_join(p_request_id)`
///   - `rejectJoin`           → RPC `reject_join(p_request_id)`
///   - `withdrawJoin`         → RPC `withdraw_join(p_request_id)`
///   - `listJoinRequests`     → RPC `list_join_requests()`
///   - `myJoinRequest`        → RPC `get_my_join_request()`
///
/// 錯誤一律映射為 `AppError`（見該檔），不直接往外拋 PostgREST 的 error 型別。
protocol FamilyAPIClient: Sendable {
    /// 建立新家庭；呼叫者自動成為第一位 owner（DB trigger 保證）。
    func createFamily(name: String) async throws -> Family

    /// 呼叫者目前所屬的家庭（Phase 1 單一家庭 MVP：一個使用者最多一個家庭）；從未建立或加入過
    /// 任何家庭則回傳 nil——LS-107 root routing 用這個結果判斷「已登入但無家庭」該不該進三岔路。
    func fetchMyFamily() async throws -> Family?

    /// 只有該家庭 owner 能成功（RLS 收斂）。
    func updateFamilyName(familyID: UUID, name: String) async throws

    /// 只有該家庭 owner 能成功（RLS 收斂）。
    func setRequireApproval(familyID: UUID, requireApproval: Bool) async throws

    /// 產生邀請碼；只有該家庭 owner 能成功。`expiresAt` 必須在未來 30 天內，
    /// `maxUses` 必須介於 1~20（RPC 端強制，逾界回 `LS017`）。
    func createInvite(familyID: UUID, role: FamilyRole, expiresAt: Date, maxUses: Int) async throws -> String

    /// 用邀請碼申請加入。
    func requestJoin(code: String) async throws -> JoinRequestOutcome

    /// 核准待審申請；只有該家庭 owner 能成功。
    func approveJoin(requestID: UUID) async throws

    /// 拒絕待審申請；只有該家庭 owner 能成功。
    func rejectJoin(requestID: UUID) async throws

    /// 撤回自己送出的待審申請；只有申請人本人能成功。
    func withdrawJoin(requestID: UUID) async throws

    /// 呼叫者名下（所有身為 owner 的家庭）目前待審的加入申請。
    func listJoinRequests() async throws -> [PendingJoinRequest]

    /// 呼叫者自己最相關的一筆申請（有 pending 一定回 pending；否則回最近一筆已處理的；
    /// 從未申請過回 nil）。
    func myJoinRequest() async throws -> MyJoinRequest?
}

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
///                              ＋反查 SELECT `public.invites`（RPC 只回 `code`，`id`／
///                              `used_count` 從表裡撈——R1 F2/F4）
///   - `fetchLatestActiveInvite` → SELECT `public.invites`（未過期、還有名額的最新一支；
///                              R1 F4，供 07 進場顯示既有碼）
///   - `revokeInvite`         → DELETE `public.invites`（owner 撤銷邀請碼的唯一路徑；
///                              沒有 `revoke_invite` RPC，見 `20260823040000_invites_write_path.sql`
///                              §3／LS-37 收斂註記，R1 F2）
///   - `fetchQuota`           → RPC `get_family_quota(p_family_id)`（LS-188 09／09b 儲存空間頁；
///                              `20260903091317_report_block_rpc.sql` §7）
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
    /// `maxUses` 必須介於 1~20（RPC 端強制，逾界回 `LS017`）。回傳完整 `InviteRecord`
    /// （含 `id`／`usedCount`），不只是 RPC 直接回的 `code`——見上方方法對照註解。
    func createInvite(familyID: UUID, role: FamilyRole, expiresAt: Date, maxUses: Int) async throws -> InviteRecord

    /// 這個家庭目前最新一支「還有效」的邀請碼（未過期、`usedCount < maxUses`）；
    /// 沒有就回 nil。R1 F4：07 進場先查這個，避免每次重開都顯示空狀態、誘使 owner 再產生
    /// 一支新碼。
    func fetchLatestActiveInvite(familyID: UUID) async throws -> InviteRecord?

    /// 撤銷（刪除）一支邀請碼；只有該家庭 owner 能成功。R1 F2：後端沒有 `revoke_invite`
    /// RPC，這是唯一的撤銷路徑——`createInvite` 在「重新產生」情境下會先呼叫這支。
    func revokeInvite(id: UUID) async throws

    /// LS-188：09／09b 儲存空間頁的用量／上限——owner／member／viewer 皆可查詢（RLS 只收斂到
    /// 自己所屬的家庭，不像 `updateFamilyName`／`setRequireApproval` 限 owner）。
    func fetchQuota(familyID: UUID) async throws -> FamilyQuota

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

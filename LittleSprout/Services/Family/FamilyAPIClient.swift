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
///   - `listMembers`          → SELECT `public.family_members` join `public.profiles`
///                              （PostgREST FK 內嵌，LS-192）
///   - `removeMember`         → DELETE `public.family_members`（owner 移除他人＝03b，
///                              自行退出＝03d／03e，同一條路徑，LS-192）
///   - `transferOwnership`    → RPC `transfer_ownership(p_family_id, p_to_user_id)`（LS-206，
///                              LS-192 / 03c）
///   - `fetchMyProfile`       → SELECT `public.profiles`（LS-192 / 02，自己這一列）
///   - `updateDisplayName`    → UPDATE `public.profiles` (display_name)（LS-192 / 02）
///   - `updateAvatarPath`     → UPDATE `public.profiles` (avatar_url)（LS-192 / 02，見
///                              `ProfileAvatarPath` 文件註解）
///   - `signedAvatarURLs`     → Storage `media` bucket `createSignedURLs`（LS-192，同
///                              `ChildAPIClient.signedAvatarURLs` 的既有實作，故意不共用——見
///                              `SupabaseChildAPIClient.signedAvatarURLs` 文件註解）
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

    /// LS-192：03 家庭成員清單——owner／member／viewer 皆可查詢（`family_members_select`
    /// 只收斂到「自己所屬的家庭」，不限角色）。依 `FamilyRole.sortRank` 排序（owner 優先），
    /// 同排名再依顯示名稱排序，避免每次重查順序跳動。
    func listMembers(familyID: UUID) async throws -> [FamilyMember]

    /// 移除成員（owner 對他人，03b）或自行退出（`userID` 傳呼叫者自己，03d／03e）——同一條
    /// `DELETE family_members` 路徑，RLS（`family_members_delete`）本身區分兩種呼叫者身份；
    /// 唯一 owner 且家庭還有其他成員時，DB trigger 回 `LS057`（LS-206）。
    func removeMember(familyID: UUID, userID: UUID) async throws

    /// 轉移 owner 身份（03c）——`transfer_ownership` RPC（LS-206），同一交易升對方、降自己。
    func transferOwnership(familyID: UUID, toUserID: UUID) async throws -> TransferOwnershipResult

    /// LS-192 / 02：呼叫者自己的 `profiles` 列。`profiles_select` 一定放行自己
    /// （`peer_profile_ids()` 包含自己），理論上不會是 0 列。
    func fetchMyProfile() async throws -> Profile

    /// PUT 語意整欄替換 `display_name`（`profiles_update` 只放行 `id = auth.uid()`，見
    /// docs/API.md §3）；`name` 的長度／空白規則由呼叫端（`ProfileEditView`）先驗，DB
    /// check 約束（1~50 字，去頭尾空白後）是最後一道防線。回傳更新後的列，供呼叫端直接
    /// 覆寫本地狀態，不必另外重查一次。
    func updateDisplayName(_ name: String) async throws -> Profile

    /// 寫入自行上傳頭像的 Storage 路徑（見 `ProfileAvatarPath` 文件註解）——呼叫前應已經
    /// 用 `ChildAvatarUploadService.uploadProfileAvatar` 把檔案傳上去，這裡只負責把路徑
    /// 寫進 `profiles.avatar_url`。回傳更新後的列。
    func updateAvatarPath(_ path: String) async throws -> Profile

    /// 把一批 `profiles.avatar_url`（僅限 Storage 路徑，`ProfileAvatarPath.isStoragePath`
    /// 為 true 的那些——外部 OAuth 網址不需要簽名，呼叫端不應該把它們傳進來）換成短效簽名
    /// URL。單一路徑簽名失敗略過、不讓整批失敗，同 `ChildAPIClient.signedAvatarURLs` 既有慣例。
    func signedAvatarURLs(forPaths paths: [String]) async throws -> [String: URL]
}

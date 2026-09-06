import Foundation

/// LS-193（LS-24 刪除帳號流程）：帳號生命週期操作的型別化 client 介面，跟 `FamilyAPIClient`
/// 分開——`delete_my_account()`／Edge Function `delete-account` 是帳號層級的操作（逐一檢查
/// 呼叫者所屬的「每一個」家庭，見 `docs/API.md` §4），不是某一個特定家庭的操作，語意上不屬於
/// `FamilyAPIClient` 既有的「家庭／邀請／加入審核」範疇。
///
/// 方法 ↔ RPC／端點對照（docs/API.md §4／§10「Edge Functions」）：
///   - `deleteMyAccount`         → RPC `delete_my_account()`（LS-143）。`LS050`（唯一 owner
///                                 且家庭還有其他成員）不是典型錯誤，見 `DeleteMyAccountOutcome`
///                                 文件註解，其餘錯誤一律 `throws`（`AppError`）。
///   - `finalizeAccountDeletion` → Edge Function `delete-account`（LS-151，service_role 執行，
///                                 真正刪除 `auth.users`）。呼叫端硬性規定：`deleteMyAccount()`
///                                 回傳 `.success` 後**立即**呼叫這支，中間不得允許使用者做任何
///                                 操作（docs/API.md §4／§10）。
protocol AccountAPIClient: Sendable {
    func deleteMyAccount() async throws -> DeleteMyAccountOutcome
    func finalizeAccountDeletion() async throws
}

/// `delete_my_account()` 的兩種正常結果。`LS050` 不是「這次呼叫失敗、使用者該重試」的錯誤，
/// 是「呼叫端該導去 04b 顯示待轉移家庭清單」的明確分流，因此獨立成回傳值的一部分，不透過
/// `throws` 讓呼叫端還得反解 `AppError.code` 才知道要不要顯示 04b——其餘錯誤（`42501` 未登入、
/// `LS057` 併發競態、網路、伺服器）維持 `throws`。
enum DeleteMyAccountOutcome: Equatable, Sendable {
    /// 情況 2／3（docs/API.md §4）：真的刪除／離開成功，`profiles.deletion_requested_at`
    /// 已標記，呼叫端下一步必須立即呼叫 `finalizeAccountDeletion()`。
    case success
    /// 情況 1：呼叫者是列出的每個家庭的唯一 owner、且該家庭還有其他成員，整個呼叫被拒絕、
    /// 不執行任何寫入——`families` 依 `family_name` 排序（docs/API.md §4）。
    case mustTransferOwnership(families: [FamilyPendingTransfer])
}

/// `LS050` 的 `DETAIL` payload（`docs/API.md` §4）：唯一 owner 需要先轉移的每個家庭。
struct FamilyPendingTransfer: Decodable, Equatable, Identifiable, Sendable {
    let familyID: UUID
    let familyName: String

    var id: UUID { familyID }

    enum CodingKeys: String, CodingKey {
        case familyID = "family_id"
        case familyName = "family_name"
    }
}

import Foundation

/// `JoinWaitingView`（06d）輪詢 `get_my_join_request` 後，依回傳結果決定接下來要做什麼——抽成
/// 獨立、可測試的純函式，理由同 `InvitePhase`（見該檔文件註解）：View 層邏輯不可測，這裡集中
/// 判斷才能單元測試釘住「拒絕／撤回／查無此筆都要回三岔路，且無殘留權限」這條票文驗收條件。
enum JoinRequestPollOutcome: Equatable {
    /// 仍是 pending，留在 06d 繼續等待、繼續輪詢。
    case stillWaiting
    /// 核准了——呼叫端接著呼叫 `FamilyStore.refreshMyFamily()`，root routing 會自動離開三岔路
    /// （同 `createFamily` 成功後的既有慣例，見 `FamilyStore` 文件）。
    case approved
    /// 拒絕、撤回，或這筆申請已經查不到了（例如 owner 撤銷了底下的邀請碼，cascade 掉這筆
    /// pending 申請，見 docs/API.md §7「設計上的硬決定」第 3 點）——三種情況對申請人而言結果
    /// 相同：沒有任何殘留權限，回三岔路。
    case returnToFork
}

enum JoinWaitingPhase {
    /// - Parameters:
    ///   - result: `get_my_join_request()` 這次輪詢的回傳（0 列時是 nil）。
    ///   - expectedRequestID: 06d 進場時（`requestJoin` 回傳 `.pending`）記下的那一筆
    ///     `request_id`——`get_my_join_request` 沒有 pending 時會回「最近一筆已處理的」，
    ///     必須確認是同一筆才能採信，避免誤讀成別次（理論上不會發生，但不假設它不會）申請的
    ///     結果。
    static func pollOutcome(for result: MyJoinRequest?, expectedRequestID: UUID) -> JoinRequestPollOutcome {
        guard let result, result.requestID == expectedRequestID else {
            return .returnToFork
        }
        switch result.status {
        case .pending:
            return .stillWaiting
        case .approved:
            return .approved
        case .rejected, .withdrawn:
            return .returnToFork
        }
    }
}

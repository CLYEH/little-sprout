import Foundation

/// 三岔路（04）之後的子路由（LS-107／LS-108）：對齊 `AuthRoute` 的既有寫法（見該檔），
/// `ForkView` 自己持有一份 `path` 陣列驅動 `NavigationStack`。
enum FamilyOnboardingRoute: Hashable {
    case createFamily
    /// 06 輸入邀請碼（含 06b／06c 錯誤態，見 `JoinCodeView`）。`initialCode` 供 deep link
    /// （`littlesprout://invite/<code>`）冷／熱啟動預填；一般從三岔路「我有邀請碼」卡片點進來
    /// 是空字串。
    case joinCode(initialCode: String)
    /// 06d 等待核准——`requestJoin` 回傳 `.pending` 後導來這裡；`familyName` 不是
    /// `request_join` 直接回的（見 `JoinCodeView` 呼叫處註解）；`submittedAt` 是送出當下的
    /// client 時間（近似 `join_requests.created_at`，供「送出時間」顯示，不必等第一次輪詢
    /// 回來才有值）。
    case joinWaiting(requestID: UUID, familyID: UUID, familyName: String, submittedAt: Date)
}

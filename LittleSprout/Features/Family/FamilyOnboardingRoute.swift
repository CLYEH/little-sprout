import Foundation

/// 三岔路（04）之後的子路由（LS-107）：對齊 `AuthRoute` 的既有寫法（見該檔），
/// `ForkView` 自己持有一份 `path` 陣列驅動 `NavigationStack`。
enum FamilyOnboardingRoute: Hashable {
    case createFamily
    /// 06 輸入邀請碼由 LS-108 實作；這裡先導到一個標記清楚的佔位畫面，見
    /// `JoinFamilyPlaceholderView`。
    case joinPlaceholder
}

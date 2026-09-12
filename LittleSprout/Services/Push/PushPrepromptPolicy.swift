import UserNotifications

/// 前置說明頁（`design/littlesprout.pen` `j7WwV`）的出現條件——純函式，同 `EULAConsentPolicy`
/// 既有慣例，方便單元測試不必真的建立 View／系統權限環境。
enum PushPrepromptPolicy {
    /// - Parameters:
    ///   - authorizationStatus: 目前系統授權狀態——非 `.notDetermined`（已同意／已拒絕／
    ///     臨時／provisional／ephemeral）一律不再顯示，即使 `hasShownBefore` 是 false
    ///     （票文範圍 1：「`UNAuthorizationStatus` 非 `.notDetermined` 時永不顯示」，這個條件
    ///     優先於「首次」）。
    ///   - hasShownBefore: 這個使用者是否已經看過這張前置頁（`PushPrepromptDisplayRecord`）。
    /// - Returns: `true`＝這次進場該自動顯示前置頁。
    ///
    /// 只管「登入後首次進時間軸自動顯示」這一條路徑——設定頁「推播通知」列在 `.notDetermined`
    /// 狀態下被點擊時一律重新導向前置頁（票文範圍 3「走第 1 項流程」），不經過這支判斷、不受
    /// `hasShownBefore` 限制（`SettingsView` 直接呈現 `PushPrepromptView`，見該檔）。
    static func shouldPresent(authorizationStatus: UNAuthorizationStatus, hasShownBefore: Bool) -> Bool {
        authorizationStatus == .notDetermined && !hasShownBefore
    }
}

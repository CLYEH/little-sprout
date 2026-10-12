import Foundation

/// LS-502：`RootView` 的根路由結果。純函式、可單元測試——`RootView.body` 只負責依結果切畫面。
///
/// 三態而非兩態的原因：冷啟動時 Keychain 的 access token 多半已過期（壽命 1h），SDK 要背景用
/// refresh token 換新，這段網路往返期間若直接路由成 `.welcome`，使用者會先看到登入頁、約 1 秒
/// 後才跳進動態。`.restoring` 讓這段時間顯示啟動佔位頁（`LaunchPlaceholderView`）。
@MainActor
enum RootRoute: Equatable {
    case authenticated
    case welcome
    case restoring

    /// - session 有效 → `.authenticated`（與 LS-502 前相同）。
    /// - session 為 nil → `.welcome`（與 LS-502 前相同）。
    /// - session 存在但已過期：還原尚未結束（`.pending`）→ `.restoring`；已結束（收到刷新結果
    ///   或逾時，`.settled`）→ `.welcome`（離線情境與 LS-502 前相同）。
    static func resolve(session: AuthSession?, now: Date, restoreState: AuthStore.RestoreState) -> RootRoute {
        if AuthStore.isSessionValid(session, asOf: now) { return .authenticated }
        if session != nil, restoreState == .pending { return .restoring }
        return .welcome
    }
}

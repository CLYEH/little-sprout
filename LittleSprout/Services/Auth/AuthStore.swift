import Foundation
import Observation

/// 把 `AuthService.currentSession` 包成 `@Observable`，讓 root routing 可以依它重繪
/// （`AuthService.currentSession` 本身不是 Observable，背景變化不會觸發任何 View 重繪，見該
/// 協定文件與 LS-55 N7）。所有會改變登入狀態的動作（Apple／Email OTP／登出）都經過這個
/// store，動作完成後立刻把結果寫進 `session`——這個屬性的變化才是驅動畫面重繪的訊號，不是
/// 直接在 View 裡讀 `authService.currentSession`。
///
/// `refreshSnapshot()` 供 App 從背景回到前景時呼叫，撿回可能在背景被其他路徑（例如 SDK
/// 的 autoRefreshToken 計時器）更新、但這個 store 還沒看到的 session 變化。
///
/// 真正驅動 `session` 的是 init 起的 `sessionUpdates` 訂閱（見下方 `observeSessionUpdatesTask`）
/// ——涵蓋「SDK 端偵測到 refresh token 被撤銷／重用而發 signedOut，但沒有經過這個 store 任何
/// 方法呼叫」的情況（LS-17 R2 merge-reviewer N5／LS-82）。init／mutating 方法後／
/// `refreshSnapshot()` 這三個快照時機仍然保留，但只是補位。**權威值一律是
/// `authService.currentSession`**：`sessionUpdates` 只當「有事發生、該重新讀」的訊號，訂閱迴圈
/// 收到事件後不直接採用事件攜帶的值，而是重讀 `currentSession`——`SupabaseAuthService` 對
/// `cachedSession` 是先寫後 yield，構造上 `currentSession` 不可能比已送達的 stream 事件更舊
/// （LS-82 PR #147 review F2）。快照路徑與訂閱路徑因此不會互相覆蓋成更舊的值，但暫態上仍可能
/// 不同步（例如背景累積多個事件、`refreshSnapshot()` 先跑一次再被訂閱迴圈追上）——會收斂，不
/// 保證每個中間值都對到一次重繪。
@MainActor
@Observable
final class AuthStore {
    private let authService: AuthService
    // Optional（有隱含預設值 nil）而非 let：讓下面 init 裡 `[weak self]` 捕捉可以放在任何位置，
    // 不受「escaping closure 捕捉 self 前，這個屬性本身必須先被賦值」這條 definite
    // initialization 規則卡住（該規則連 weak 捕捉也算「使用 self」）。`@ObservationIgnored`：
    // 排除在 `@Observable` 巨集的追蹤之外（本來就不是該讓 View 依它重繪的狀態），順便讓這個
    // `Sendable`（`Task<Void, Never>`）屬性能被 nonisolated 的 `deinit` 直接讀取／呼叫
    // `cancel()`（LS-82 PR #147 review F3 實測：`@ObservationIgnored` 就夠，不需要再疊
    // `nonisolated(unsafe)`——那會把這個屬性永久移出 isolation 檢查，日後若有其他地方從
    // nonisolated context 重新指派它，編譯器不會攔）。
    @ObservationIgnored
    private var observeSessionUpdatesTask: Task<Void, Never>?

    private(set) var session: AuthSession?

    /// LS-502：冷啟動「還原中」狀態。init 時讀到「存在但已過期」的 session（Keychain 裡 1h 的
    /// access token 隔一段時間再開 app 必過期），SDK 會在背景用 refresh token 換新——這段網路
    /// 往返期間不能直接路由到登入頁（會閃一下才進動態），所以先 `.pending`，由
    /// `RootRoute.resolve` 顯示啟動佔位頁。session 為 nil 或一開始就有效 → 直接 `.settled`。
    enum RestoreState: Equatable, Sendable {
        case pending
        case settled
    }

    /// 還原逾時：離線時 SDK 的 refresh 失敗但不一定發任何事件，沒有這個兜底會永遠停在佔位頁。
    /// 逾時後依當下（仍過期的）session 路由 → 登入頁，與 LS-502 之前的離線行為相同。
    static let restoreTimeout: Duration = .seconds(5)

    /// 實際使用的逾時長度：生產路徑一律 `restoreTimeout`；測試可注入短值（LS-502 R1b）。
    @ObservationIgnored
    private let restoreTimeoutDuration: Duration

    private(set) var restoreState: RestoreState

    @ObservationIgnored
    private var restoreTimeoutTask: Task<Void, Never>?

    /// 最近一次觀察到的路由是否為已登入（見 `sceneDidBecomeActive()`）。
    @ObservationIgnored
    private var wasAuthenticated = false

    init(authService: AuthService, restoreTimeout: Duration = AuthStore.restoreTimeout) {
        self.authService = authService
        self.restoreTimeoutDuration = restoreTimeout
        let initialSession = authService.currentSession
        self.session = initialSession
        let needsRestore = initialSession != nil && !Self.isSessionValid(initialSession, asOf: Date())
        self.restoreState = needsRestore ? .pending : .settled
        observeSessionUpdatesTask = Task { [weak self] in
            for await _ in authService.sessionUpdates {
                guard let self, !Task.isCancelled else { return }
                self.session = authService.currentSession
                // 只有「重讀後 session 為 nil（刷新失敗／signOut）或已有效（刷新成功）」才算還原
                // 結束：SDK 的第一個事件 `.initialSession` 帶的就是 Keychain 裡那份過期 session
                // （`emitLocalSessionAsInitialSession`，見 `SupabaseClientFactory`），緊接著才是
                // 背景刷新的 `tokenRefreshed`／`signedOut`——見到過期的那一筆不能結束。
                if self.session == nil || self.isAuthenticated() { self.settleRestore() }
            }
        }
        if needsRestore { startRestoreTimeout() }
    }

    private func startRestoreTimeout() {
        restoreTimeoutTask?.cancel()
        let duration = restoreTimeoutDuration
        restoreTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.settleRestore()
        }
    }

    /// 熱回前景：app 在背景超過 access token 壽命（1h）再回前景時，store 早已 `.settled`、
    /// session 已過期，`RootRoute` 會直接落登入頁，等 SDK 在 didBecomeActive 後刷新才切回
    /// ——與冷啟動同一個閃爍。這裡把「存在但已過期」的 session 重新標成還原中，規則同 init
    /// （事件或逾時結束）。`RootView+ScenePhase` 在 `.inactive` 與 `.active` 都呼叫（回前景先經
    /// `.inactive`，body 此刻就會重算路由，等到 `.active` 才設會先閃幾幀登入頁）；已在
    /// `.pending` 不重啟逾時，重複呼叫無副作用。
    ///
    /// 只在「進背景前路由是已登入」時才重設（`wasAuthenticated`）：使用者停在登入頁（過期 session、
    /// 離線）時每次回前景若都換成佔位頁，會清掉登入頁上的 OTP／nonce 等輸入狀態。`wasAuthenticated`
    /// 由 `sceneDidEnterBackground()` 與本方法在 session 有效時刷新，重設成 pending 時消耗掉
    /// （刷新失敗落登入頁後，後續 `.inactive` 往返不再重設）。
    func sceneDidBecomeActive() {
        if isAuthenticated() {
            wasAuthenticated = true
            return
        }
        guard wasAuthenticated, restoreState == .settled, session != nil else { return }
        wasAuthenticated = false
        restoreState = .pending
        startRestoreTimeout()
    }

    /// `RootView+ScenePhase` 在 `.background` 呼叫：記下「進背景當下路由是否為已登入」。
    func sceneDidEnterBackground() {
        wasAuthenticated = isAuthenticated()
    }

    /// 事件與逾時兩條路徑都走這裡；兩者都在 MainActor 上，`guard` 保證 `.settled` 只設一次，
    /// 並在第一條抵達時取消另一條（逾時 Task 收到事件後取消）。
    private func settleRestore() {
        guard restoreState == .pending else { return }
        restoreState = .settled
        restoreTimeoutTask?.cancel()
        restoreTimeoutTask = nil
    }

    // 這裡的 cancel 不只停掉這個 store 自己的訂閱迴圈——`sessionUpdates` 是一次性訂閱，
    // consumer 取消後底層 stream 永久終止（實測，見 `AuthService.sessionUpdates` 協定文件）。
    // 目前生產路徑 `authService` 與 `AuthStore` 在 `LittleSproutApp` 成對建立、同生共死，
    // 沒有現行 bug；但若日後 `authService` 被提升為跨多個 store 共用的實例，這裡的 cancel
    // 會讓下一個訂閱它的 store 永遠收不到事件、且不會有任何錯誤（LS-82 PR #147 review F1）。
    deinit {
        observeSessionUpdatesTask?.cancel()
        restoreTimeoutTask?.cancel()
    }

    /// 離線開 app 時 `currentSession` 可能回傳非 nil 但已過期的 session（LS-55 N1／I5）；
    /// root routing 必須用這個屬性，不能只判斷 `session != nil`。
    func isAuthenticated(asOf now: Date = Date()) -> Bool {
        AuthStore.isSessionValid(session, asOf: now)
    }

    static func isSessionValid(_ session: AuthSession?, asOf now: Date) -> Bool {
        guard let session else { return false }
        return session.expiresAt > now
    }

    @discardableResult
    func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession {
        let session = try await authService.signInWithApple(idToken: idToken, nonce: nonce)
        self.session = session
        return session
    }

    /// 見 `AuthService.signInWithGoogle` 協定文件：使用者取消時 `authService` 會原樣拋
    /// `ASWebAuthenticationSessionError`（不是 `AppError`）——這裡不做任何特殊判斷，跟其他
    /// 失敗一樣原封不動往上傳；辨識「取消該靜默」是呼叫端（`WelcomeView`）的責任。
    @discardableResult
    func signInWithGoogle(
        launchFlow: @MainActor @Sendable (_ url: URL) async throws -> URL
    ) async throws -> AuthSession {
        let session = try await authService.signInWithGoogle(launchFlow: launchFlow)
        self.session = session
        return session
    }

    /// 見 `AuthService.signInWithPassword` 協定文件（LS-164）。
    @discardableResult
    func signInWithPassword(email: String, password: String) async throws -> AuthSession {
        let session = try await authService.signInWithPassword(email: email, password: password)
        self.session = session
        return session
    }

    func sendEmailOTP(email: String) async throws {
        try await authService.sendEmailOTP(email: email)
    }

    @discardableResult
    func verifyEmailOTP(email: String, token: String) async throws -> AuthSession {
        let session = try await authService.verifyEmailOTP(email: email, token: token)
        self.session = session
        return session
    }

    func signOut() async throws {
        try await authService.signOut()
        session = nil
    }

    /// LS-193：帳號刪除完成（04g）後強制清掉本地 session——底層帳號在 Edge Function
    /// `delete-account` 那一步已經被刪除，這裡再呼叫一般的 `signOut()` 有可能因為 GoTrue 端
    /// 找不到對應使用者而失敗（見該端點冪等語意，`docs/API.md` §10）；但無論這次登出的網路
    /// 呼叫成功與否，帳號確實已經不存在，本地 `session` 都必須清除——不能讓使用者卡在「按了
    /// 『回到登入畫面』卻沒有反應」（`signOut()` 若拋錯，`session` 不會被寫成 nil，root
    /// routing 就不會離開已登入畫面樹）。因此這裡吞掉 `signOut()` 的錯誤，只保證 `session`
    /// 最終被寫成 nil。
    func forceSignOutLocally() async {
        try? await authService.signOut()
        session = nil
    }

    func refreshSnapshot() {
        session = authService.currentSession
    }

    #if DEBUG
    /// LS-190：`TapTargetGateHarness.eulaConsentToTimelineHost` 用——同步灌一個 session，不經過
    /// 任何登入方法即可讓 `RootView.AuthenticatedGate` 判定「已登入」——同
    /// `TimelineStore.seedForPreview` 的角色與理由（見該檔）。`PreviewAuthService.currentSession`
    /// 預設是 `nil`（沒有任何登入方法會被 harness 呼叫），沒有這支方法 `AuthenticatedGate`
    /// 永遠停在「session 為 nil」的防禦分支。整支 `#if DEBUG` 圍住，Release build 不會編到。
    func seedSessionForPreview(_ session: AuthSession) {
        self.session = session
    }
    #endif
}

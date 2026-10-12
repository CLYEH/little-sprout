#if DEBUG
import SwiftUI

extension TapTargetGateHarness {
    @MainActor
    @ViewBuilder
    static func welcomeOrForkViewHost(for screen: TapTargetGateScreenName) -> some View {
        switch screen {
        case .forkViewNoFamily: ForkViewSignOutHost()
        case .familyLookupFailed: ForkViewSignOutHost(showsLookupFailed: true)
        default: welcomeHost
        }
    }
}

/// LS-505：已登入、無家庭的一般三岔路頁（或 `showsLookupFailed`＝家庭查詢失敗兜底頁）harness host。依 `authStore.session == nil` 切回
/// `WelcomeView`，鏡像 `RootView` 的 `.welcome` 分支，讓 UITest 能驗證「點登出 → 回到登入頁」。
struct ForkViewSignOutHost: View {
    var showsLookupFailed = false
    @State private var authStore = ForkViewSignOutHost.makeAuthStore()
    @State private var pendingInviteCode: String?

    var body: some View {
        if authStore.session == nil {
            WelcomeView(authStore: authStore)
        } else if showsLookupFailed {
            FamilyLookupFailedView(
                message: "伺服器發生問題，請稍後再試一次。",
                signOut: { try await authStore.signOut() },
                retry: {}
            )
        } else {
            ForkView(
                authStore: authStore, familyStore: .preview(), childrenStore: .preview(),
                timelineStore: .preview(), albumsStore: .preview(), eulaStore: .preview(shouldPresent: false),
                accountAPIClient: PreviewAccountAPIClient(), resumer: .preview(),
                pendingInviteCode: $pendingInviteCode
            )
        }
    }

    private static func makeAuthStore() -> AuthStore {
        let store = AuthStore.preview()
        store.seedSessionForPreview(
            AuthSession(userID: UUID(), email: "fork-harness@example.com", expiresAt: .distantFuture)
        )
        return store
    }
}
#endif

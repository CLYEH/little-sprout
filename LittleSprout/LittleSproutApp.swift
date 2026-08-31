import SwiftUI

@main
struct LittleSproutApp: App {
    @State private var authStore: AuthStore
    // LS-107：`familyStore` 跟 `authStore` 一樣在 App 層建一次、隨 app 存活——root routing
    // 依賴它的 `myFamily` 判斷要不要進三岔路，若每次重繪都重建會遺失狀態、也違反 LS-18
    // comment `1fce1645`「不可重建 store 而不重建 service」。
    @State private var familyStore: FamilyStore
    /// LS-108：`littlesprout://invite/<code>` deep link（LS-39 已註冊 scheme）冷／熱啟動皆走
    /// `.onOpenURL`——寫進這裡，`ForkView` 是唯一消費者（見該檔文件）。這一層只負責接住 URL、
    /// 解析出碼，不判斷「現在該不該導頁」，那是 `ForkView` 才知道的事（是否已登入、是否已有
    /// 家庭）。
    @State private var pendingInviteCode: String?

    init() {
        let client = SupabaseClientFactory.makeClient()
        _authStore = State(initialValue: AuthStore(authService: SupabaseAuthService(client: client)))
        _familyStore = State(initialValue: FamilyStore(apiClient: SupabaseFamilyAPIClient(client: client)))
    }

    var body: some Scene {
        WindowGroup {
            RootView(authStore: authStore, familyStore: familyStore, pendingInviteCode: $pendingInviteCode)
                .onOpenURL { url in
                    if let code = InviteCodeParser.code(fromDeepLink: url) {
                        pendingInviteCode = code
                    }
                }
        }
    }
}

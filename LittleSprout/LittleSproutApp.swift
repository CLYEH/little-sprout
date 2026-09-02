import SwiftUI

@main
struct LittleSproutApp: App {
    @State private var authStore: AuthStore
    // LS-107：`familyStore` 跟 `authStore` 一樣在 App 層建一次、隨 app 存活——root routing
    // 依賴它的 `myFamily` 判斷要不要進三岔路，若每次重繪都重建會遺失狀態、也違反 LS-18
    // comment `1fce1645`「不可重建 store 而不重建 service」。
    @State private var familyStore: FamilyStore
    // LS-113：跟 `familyStore` 同理，隨 app 存活——09／10 畫面依它的 `children`／`myRole`
    // 判斷要不要重查，若每次重繪都重建會遺失狀態。
    @State private var childrenStore: ChildrenStore
    /// LS-125：日記編輯器（`DiaryEditorView`）用的 client——不是 `@State`：兩者都是不可變的
    /// 純 service 物件（同 `familyStore` 內部包的 `SupabaseFamilyAPIClient`），本身不 Observable
    /// 也不需要跨重繪保留可變狀態，草稿狀態的持久性由 `DiaryComposerStore`（畫面等級，見該檔）
    /// 負責，不需要在這裡另外包一層 store。
    let diaryAPIClient: DiaryAPIClient
    let mediaUploadService: MediaUploadService
    /// LS-108：`littlesprout://invite/<code>` deep link（LS-39 已註冊 scheme）冷／熱啟動皆走
    /// `.onOpenURL`——寫進這裡，`ForkView` 是唯一消費者（見該檔文件）。這一層只負責接住 URL、
    /// 解析出碼，不判斷「現在該不該導頁」，那是 `ForkView` 才知道的事（是否已登入、是否已有
    /// 家庭）。
    @State private var pendingInviteCode: String?

    init() {
        let client = SupabaseClientFactory.makeClient()
        _authStore = State(initialValue: AuthStore(authService: SupabaseAuthService(client: client)))
        _familyStore = State(initialValue: FamilyStore(apiClient: SupabaseFamilyAPIClient(client: client)))
        _childrenStore = State(initialValue: ChildrenStore(apiClient: SupabaseChildAPIClient(client: client)))
        diaryAPIClient = SupabaseDiaryAPIClient(client: client)
        mediaUploadService = SupabaseMediaUploadService(client: client)
    }

    var body: some Scene {
        WindowGroup {
            // LS-95：≥44pt 點擊目標機械 gate 的掛載點——`TapTargetGateHarness.activeScreen`
            // 只有在 `TapTargetGateTests`／`TapTargetGateSelfTests` 設了
            // `LS_TAP_TARGET_GATE_SCREEN` 這個 launch environment 變數時才非 nil，一般使用者
            // 啟動 app 一定走下面的 `RootView` 路徑，行為與這行加入前完全一致（見該檔文件註解）。
            #if DEBUG
            if let screen = TapTargetGateHarness.activeScreen {
                TapTargetGateHarness.hostView(for: screen)
            } else {
                rootView
            }
            #else
            rootView
            #endif
        }
    }

    @ViewBuilder
    private var rootView: some View {
        RootView(
            authStore: authStore,
            familyStore: familyStore,
            childrenStore: childrenStore,
            diaryAPIClient: diaryAPIClient,
            mediaUploadService: mediaUploadService,
            pendingInviteCode: $pendingInviteCode
        )
        .onOpenURL { url in
            if let code = InviteCodeParser.code(fromDeepLink: url) {
                pendingInviteCode = code
            }
        }
    }
}

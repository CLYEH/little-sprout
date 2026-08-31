import SwiftUI

/// App 的根視圖：依登入狀態在「歡迎登入」與「已登入內容」之間切換。
///
/// `AuthStore.session` 是 `@Observable`，這裡讀它才會在登入/登出時觸發重繪——直接讀
/// `AuthService.currentSession`（非 Observable）不會（見 `AuthStore` 文件／LS-55 N7）。
/// `scenePhase` 轉 `.active` 時補撿一次快照，涵蓋「本 store 沒有主動呼叫、但背景已經
/// 改變 session」的情況（例如 SDK 的 autoRefreshToken 計時器）。
struct RootView: View {
    let authStore: AuthStore
    let familyStore: FamilyStore

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if authStore.isAuthenticated() {
                AuthenticatedGate(authStore: authStore, familyStore: familyStore)
            } else {
                WelcomeView(authStore: authStore)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                authStore.refreshSnapshot()
            }
        }
    }
}

/// LS-107：已登入之後，先確定「有沒有家庭」才知道要進三岔路（`ForkView`）還是主畫面
/// （`AuthenticatedRootView`）——`familyStore.myFamily` 是這個判斷的唯一依據，建立家庭
/// 成功後它會被直接設成新家庭，這裡下一次重繪就自動切到主畫面，不需要任何手動導航
/// （見 `FamilyStore` 文件註解／LS-18 comment `1fce1645`）。
///
/// 查詢失敗時刻意不當成「沒有家庭」處理：那樣會讓已經有家庭、只是網路暫時失敗的使用者被
/// 誤導進三岔路、看起來像能重新建立一個家庭。
///
/// R1 F1：`.task(id: authStore.session?.userID)`——不是單純的 `.task { if lookupState ==
/// .idle { ... } }`。`familyStore` 隨 app 存活，登出不會重置它；若只看 `lookupState`，
/// 第二位在同一台裝置登入的使用者會因為 store 裡還殘留第一位的 `.success` 狀態而被整個
/// 跳過查詢，直接沿用第一位的家庭與邀請碼。這裡改成每次 user id 變動都呼叫
/// `familyStore.syncOwner(to:)`——id 不同就先歸零再視情況重查，見該方法文件註解。
///
/// R2 N5 訂正：「登出」不是這支 `.task(id:)` 處理的——`AuthenticatedGate` 本身（連同這個
/// `.task`）會在 `authStore.isAuthenticated()` 變 false 的當下整個被 `RootView.body` 移出畫面
/// 樹，`.task(id:)` 只會被**取消**，不會再以 `id: nil` 重新啟動一次；`syncOwner(to: nil)`
/// 因此在這條路徑上永遠不會被呼叫到。登出時真正負責歸零 `FamilyStore` 的是
/// `SettingsView.signOut()` 成功後直接呼叫的 `familyStore.reset()`——兩個入口分工：這裡管
/// 「已登入狀態下換人／首次登入」，登出清理是另一條路徑。
private struct AuthenticatedGate: View {
    let authStore: AuthStore
    let familyStore: FamilyStore

    var body: some View {
        Group {
            switch familyStore.lookupState {
            case .idle, .submitting:
                ProgressView("正在確認你的家庭…")
            case .failure(let error):
                FamilyLookupFailedView(message: error.userFacingMessage) {
                    Task { await familyStore.refreshMyFamily() }
                }
            case .success:
                if familyStore.myFamily != nil {
                    AuthenticatedRootView(authStore: authStore, familyStore: familyStore)
                } else {
                    ForkView(authStore: authStore, familyStore: familyStore)
                }
            }
        }
        .task(id: authStore.session?.userID) {
            await familyStore.syncOwner(to: authStore.session?.userID)
        }
    }
}

/// 查詢「我的家庭」失敗（多半是網路）時的重試畫面——沒有對應的 .pen 設計稿：這是一個純技術性
/// 的錯誤兜底，不是產品要求的畫面，維持最簡單的系統風格文字＋按鈕，不套用沖印品母題。
private struct FamilyLookupFailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.item) {
            Text(message)
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
                .multilineTextAlignment(.center)
            Button("重試", action: retry)
                .appFont(.body, weight: .semibold)
        }
        .padding(AppSpacing.screenPad)
    }
}

/// 依 horizontal size class 切換版面的已登入根視圖。
///
/// selection 存在這一層而非各自的子視圖，所以 iPad 旋轉／分割畫面造成 size class
/// 改變時，使用者停留的區塊會被保留。
struct AuthenticatedRootView: View {
    let authStore: AuthStore
    let familyStore: FamilyStore

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: AppSection = .timeline

    var body: some View {
        if horizontalSizeClass == .regular {
            SectionSplitView(authStore: authStore, familyStore: familyStore, selection: $selection)
        } else {
            SectionTabView(authStore: authStore, familyStore: familyStore, selection: $selection)
        }
    }
}

/// Compact（iPhone 直向）：四分頁 TabView。
private struct SectionTabView: View {
    let authStore: AuthStore
    let familyStore: FamilyStore
    @Binding var selection: AppSection

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppSection.allCases) { section in
                NavigationStack {
                    SectionContentView(section: section, authStore: authStore, familyStore: familyStore)
                }
                .tabItem { Label(section.title, systemImage: section.systemImage) }
                .tag(section)
            }
        }
    }
}

/// Regular（iPad、iPhone 橫向 Max）：sidebar 列四區塊的 NavigationSplitView。
private struct SectionSplitView: View {
    let authStore: AuthStore
    let familyStore: FamilyStore
    @Binding var selection: AppSection

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: sidebarSelection) { section in
                Label(section.title, systemImage: section.systemImage)
            }
            .navigationTitle("Little Sprout")
        } detail: {
            // 已知債：detail 欄共用單一 NavigationStack；第一張含 push destination 的票
            // 需處理「iPad 切換 section 重置 detail stack」（可用 .id(selection)）。
            NavigationStack {
                SectionContentView(section: selection, authStore: authStore, familyStore: familyStore)
            }
        }
    }

    /// `List` 的單選 API 只接受 optional binding；取消選取（nil）時保持原區塊，
    /// 否則 detail 會變成空白畫面。
    /// 本 binding 僅在 regular 寬度成立；collapsed split view 需要 nil 才能返回。
    private var sidebarSelection: Binding<AppSection?> {
        Binding(
            get: { selection },
            set: { selection = $0 ?? selection }
        )
    }
}

/// 兩種版面共用的內容切換器，確保 compact／regular 顯示的是同一組畫面。
struct SectionContentView: View {
    let section: AppSection
    let authStore: AuthStore
    let familyStore: FamilyStore

    var body: some View {
        content
            .navigationTitle(section.title)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .timeline: TimelineView()
        case .albums: AlbumsView()
        case .children: ChildrenView()
        case .settings: SettingsView(authStore: authStore, familyStore: familyStore)
        }
    }
}

#Preview("Compact") {
    AuthenticatedRootView(authStore: .preview(), familyStore: .preview())
        .environment(\.horizontalSizeClass, .compact)
}

#Preview("Regular") {
    AuthenticatedRootView(authStore: .preview(), familyStore: .preview())
        .environment(\.horizontalSizeClass, .regular)
}

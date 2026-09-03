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
    let childrenStore: ChildrenStore
    let timelineStore: TimelineStore
    /// LS-125：`DiaryEditorView` 用的 client，原樣轉手往下傳到 `TimelineView`（見
    /// `LittleSproutApp` 文件註解——不是 `@State`，這裡也只是單純轉手）。
    let diaryAPIClient: DiaryAPIClient
    let mediaUploadService: MediaUploadService
    /// LS-108 deep link：見 `ForkView` 文件註解，這裡只是原樣轉手往下傳。
    @Binding var pendingInviteCode: String?

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if authStore.isAuthenticated() {
                AuthenticatedGate(
                    authStore: authStore,
                    familyStore: familyStore,
                    childrenStore: childrenStore,
                    timelineStore: timelineStore,
                    diaryAPIClient: diaryAPIClient,
                    mediaUploadService: mediaUploadService,
                    pendingInviteCode: $pendingInviteCode
                )
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
    let childrenStore: ChildrenStore
    let timelineStore: TimelineStore
    let diaryAPIClient: DiaryAPIClient
    let mediaUploadService: MediaUploadService
    @Binding var pendingInviteCode: String?

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
                    AuthenticatedRootView(
                        authStore: authStore, familyStore: familyStore, childrenStore: childrenStore,
                        timelineStore: timelineStore, diaryAPIClient: diaryAPIClient,
                        mediaUploadService: mediaUploadService
                    )
                } else {
                    ForkView(authStore: authStore, familyStore: familyStore, pendingInviteCode: $pendingInviteCode)
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
    let childrenStore: ChildrenStore
    let timelineStore: TimelineStore
    let diaryAPIClient: DiaryAPIClient
    let mediaUploadService: MediaUploadService

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: AppSection = .timeline

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                SectionSplitView(
                    authStore: authStore, familyStore: familyStore, childrenStore: childrenStore,
                    timelineStore: timelineStore, diaryAPIClient: diaryAPIClient,
                    mediaUploadService: mediaUploadService, selection: $selection
                )
            } else {
                SectionTabView(
                    authStore: authStore, familyStore: familyStore, childrenStore: childrenStore,
                    timelineStore: timelineStore, diaryAPIClient: diaryAPIClient,
                    mediaUploadService: mediaUploadService, selection: $selection
                )
            }
        }
        // LS-113：建立家庭後可接、可跳過的寶貝建檔步驟（見 `FamilyStore.showsChildOnboarding`
        // 文件註解）。`CreateChildView` 呼叫環境 `dismiss()` 時，這裡的 `set` 分支會呼叫
        // `dismissChildOnboarding()` 把旗標寫回 false——不是直接綁 `private(set)` 屬性
        // （`FamilyStore` 一貫的作法是只透過方法變動狀態，不對外暴露可寫入的屬性）。
        .fullScreenCover(isPresented: Binding(
            get: { familyStore.showsChildOnboarding },
            set: { isPresented in
                if !isPresented { familyStore.dismissChildOnboarding() }
            }
        )) {
            NavigationStack {
                CreateChildView(childrenStore: childrenStore)
            }
        }
    }
}

/// Compact（iPhone 直向）：四分頁 TabView。
///
/// LS-136：系統 `.tabItem` 列（文字＋圖示）已隱藏（`.toolbar(.hidden, for: .tabBar)`），
/// 底部改疊 `SectionTabBar`（`cmp/Tab Bar` 全字級純 icon 浮動膠囊）；`.tabItem` 本身仍保留
/// ——`TabView` 靠它辨識/註冊分頁與驅動 `selection` binding，只是視覺上不顯示。
///
/// merge-review R1 M1：`.safeAreaInset(edge: .bottom) { SectionTabBar… } ` 與
/// `.toolbar(.hidden, for: .tabBar)` **必須掛在同一層**——每個分頁 `NavigationStack` 的
/// **根內容**（`SectionContentView`）上，不是外層 `TabView`。R1 一度把 `safeAreaInset` 掛在
/// `TabView`：`TabView` 是所有分頁（含各分頁內用 `.navigationDestination` push 出來的
/// `DiaryEditorView`／`DiaryDetailView`）共同的、永遠不變的祖先，膠囊因此在 push 進編輯器／
/// 詳情頁後依然留在畫面上，跟這兩個畫面自己的 `.toolbar(.hidden, for: .tabBar)`（LS-125／
/// LS-126 QA 對稿 FAIL 修法）疊出「Action Bar＋膠囊」兩條底部帶，且與核可稿 12／13 板（編輯器
/// ／詳情，稿面完全沒有 Tab Bar 節點）不符。改掛在 `SectionContentView` 這個根內容實例上之後，
/// push 新目的地會把根內容從畫面上換掉，`safeAreaInset` 插入的膠囊隨之自然消失——不需要額外
/// 邏輯，和 `.toolbar(.hidden, for: .tabBar)` 消失的原理一致（見下方回歸測試
/// `SectionTabBarPushRegressionTests`）。
///
/// 捲動內容底部 inset 契約（motifs.md「Tab Bar 全字級純 icon」：預設 98／AX3 122＝34＋
/// 膠囊高）不需要在四個 tab-root 畫面各自寫死——`.safeAreaInset(edge: .bottom)` 掛在這一層，
/// 會把 `SectionTabBar` 的高度自動疊加進每個子畫面（含各自的 `ScrollView`／`List`）繼承到的
/// safe area，效果等同系統原本 `.tabItem` 列本來就會做的事——底部 34pt home indicator 帶則是
/// 裝置既有的系統 safe area，不需要另外加。
private struct SectionTabView: View {
    let authStore: AuthStore
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore
    let timelineStore: TimelineStore
    let diaryAPIClient: DiaryAPIClient
    let mediaUploadService: MediaUploadService
    @Binding var selection: AppSection

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppSection.allCases) { section in
                NavigationStack {
                    SectionContentView(
                        section: section, authStore: authStore, familyStore: familyStore,
                        childrenStore: childrenStore, timelineStore: timelineStore,
                        diaryAPIClient: diaryAPIClient, mediaUploadService: mediaUploadService
                    )
                    // LS-136 實測發現（R1）：掛在外層 `TabView` 的 `.toolbar(.hidden, for: .tabBar)`
                    // 只隱藏視覺渲染，底下的原生 `UITabBarItem` 仍留在 accessibility tree 裡、
                    // 且真的 hittable（XCUITest 量到兩顆同 label「相簿」的 button 疊在同一塊
                    // 螢幕區域，兩顆 `isHittable` 都是 true）——`.accessibilityHidden` 掛在
                    // tabItem 的 `Label` 上也不生效（tabItem closure 內容會被橋接成
                    // `UITabBarItem`，不走一般 SwiftUI accessibility modifier 鏈）。改成掛在
                    // **每個分頁自己的內容**上（而不是外層 TabView），才會真的把該分頁對應的
                    // 原生列從畫面與 accessibility tree 一併移除；`SectionTabBar` 是全畫面唯一
                    // 剩下的、可被 VoiceOver 找到的分頁路徑。
                    .toolbar(.hidden, for: .tabBar)
                    // merge-review R2 M1 修法：見上方型別文件註解——掛在根內容上，push 之後
                    // 自然消失，不影響 `DiaryEditorView`／`DiaryDetailView` 自己的釘底 Action Bar。
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        SectionTabBar(selection: $selection)
                            // .pen `cmp/Tab Bar` instance x:16（兩側同值，不隨 AX3／畫面寬度
                            // 變動）——硬寫水平邊界，不是 `$screen-pad`（24）：這是浮動膠囊自己
                            // 的邊界，不是畫面內容邊界，兩者剛好不同數字（見 Notes `LuHbv`）。
                            .padding(.horizontal, 16)
                    }
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
    let childrenStore: ChildrenStore
    let timelineStore: TimelineStore
    let diaryAPIClient: DiaryAPIClient
    let mediaUploadService: MediaUploadService
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
                SectionContentView(
                    section: selection, authStore: authStore, familyStore: familyStore,
                    childrenStore: childrenStore, timelineStore: timelineStore,
                    diaryAPIClient: diaryAPIClient, mediaUploadService: mediaUploadService
                )
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
    let childrenStore: ChildrenStore
    let timelineStore: TimelineStore
    let diaryAPIClient: DiaryAPIClient
    let mediaUploadService: MediaUploadService

    var body: some View {
        content
            .navigationTitle(section.title)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .timeline:
            TimelineView(
                familyStore: familyStore, childrenStore: childrenStore, timelineStore: timelineStore,
                diaryAPIClient: diaryAPIClient, mediaUploadService: mediaUploadService
            )
        case .albums: AlbumsView()
        case .children: ChildrenManagementView(familyStore: familyStore, childrenStore: childrenStore)
        case .settings:
            SettingsView(
                authStore: authStore, familyStore: familyStore, childrenStore: childrenStore,
                timelineStore: timelineStore
            )
        }
    }
}

#if DEBUG
#Preview("Compact") {
    AuthenticatedRootView(
        authStore: .preview(), familyStore: .preview(), childrenStore: .preview(), timelineStore: .preview(),
        diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService()
    )
    .environment(\.horizontalSizeClass, .compact)
}

#Preview("Regular") {
    AuthenticatedRootView(
        authStore: .preview(), familyStore: .preview(), childrenStore: .preview(), timelineStore: .preview(),
        diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService()
    )
    .environment(\.horizontalSizeClass, .regular)
}
#endif

import SwiftUI

/// 寶貝詳情・成長區塊（LS-312，`design/littlesprout.pen` `jp6ka`〔01 iPhone〕／`DHwk2`〔04
/// 空狀態，`growthStore.isEmpty` 時自動切換〕／`pjrd7`〔06 iPad，`horizontalSizeClass ==
/// .regular` 時切換，同 `ChildrenManagementView.compactLayout`/`regularLayout` 既有分流
/// 慣例〕）。
///
/// 畫面級屬性（Notes `mfafV`→`PgHMe`／`tMMVT`／`H58CA`，逐條落地）：隱藏 Tab Bar ✗（一般
/// push，Tab Bar 維持顯示——本視圖不呼叫 `.toolbar(.hidden, for: .tabBar)`）；標題 01／04
/// 系統 large（`child.name`，不覆寫 display mode），**06 例外**（R2，merge-review R1 m2）：
/// Notes 06 那列寫「自訂（Identity Header 內 Name）」——系統標題不該再重複印一次名字，
/// `horizontalSizeClass == .regular` 時改空字串＋`.inline`，名字只由 `identityHeader`
/// 顯示一次；釘底動作帶無；深色靠 token 全自動反轉，紙卡（`GrowthChartCardView`）刻意不隨
/// theme 變色；AX3 靠 `GrowthSegmentedControl`／`GrowthChartCardView` 各自讀
/// `dynamicTypeSize` 切換直式堆疊與 X 軸刻度密度；iPad 見 `regularLayout`。
///
/// **導覽入口**（LS-312 補記，orchestrator 裁決）：`ChildrenManagementView` 的寶貝列改推這支
/// 畫面（見 `ChildrenManagementView+Detail.swift`），09b（`EditChildView`）改從「編輯」入口
/// 進入。`editDestination` 刻意用型別抹除的目的地建構閉包（不是耦合 `ChildrenRoute`）——這支
/// 畫面本身要維持可獨立經 `TapTargetGateHarness`／`#Preview` 建構（不依賴 `ChildrenRoute`／
/// `ChildrenManagementView` 的導覽情境），呼叫端各自決定要推去哪裡。
///
/// 「編輯」刻意放在 Identity Header（body content），不是系統 `ToolbarItem`——同
/// `GrowthMeasurementFormView`「取消」鈕文件註解點名的既有教訓：系統 nav bar bar
/// button item 熱區不受 `.frame()` 影響，R1 曾放在 `ToolbarItem` 實測量到 56×36pt，低於 44pt
/// 下限（`TapTargetGateTests.testChildrenManagementViewRowOpensDetailNotEdit` 抓到）。
///
/// **`growthStore` 生命週期**（R2，merge-review R1 M1，orchestrator 裁決）：改收 `child`＋
/// `apiClient`，`@State private var growthStore: GrowthStore?` 只在 `.task(id: child.id)`
/// 內、`GrowthStore.needsRebuild(current:forChildID:)` 判定要重建時才換一顆——同一個孩子
/// parent 重繪（例如 `ChildrenStore` 頭像簽名 URL 重簽）不會清空重讀；換孩子（iPad
/// `regularLayout` 側欄切 `selectedChildID`）`child.id` 真的變了才重建，避免顯示錯的孩子。
/// `body` 用 `growthStore?.childID == child.id` 這個條件（不只判 nil）決定要不要渲染
/// `content(_:)`——換孩子那一瞬間舊 store 還在但孩子已經不對，這裡會先落回 `ProgressView`，
/// 不會把 A 孩子的資料誤植到 B 孩子名下。
///
/// **姓名／生日一律讀 `child`，不讀 `growthStore`**（R3，merge-review R2 M1-a，orchestrator
/// 裁決）：`GrowthStore.childName`／`childBirthday` 只在 `init` 寫死一次，`needsRebuild` 同一個
/// 孩子不重建之後就不會再更新——編輯寶貝存檔（同一 `child.id`、`ChildrenStore.updateChild()` →
/// `reloadChildrenList()`）之後，`identityHeader()`／空狀態文案／曲線月齡軸若繼續讀
/// `growthStore.childName`／`childBirthday` 會停在舊值。Identity Header、空狀態文案的
/// `childName:`、曲線的 `curvePoints(for:birthday:)` 都改吃 `child.name`／`child.birthday`
/// （呼叫端 `ChildrenManagementView` 重繪時 `child` 本身就是新值，不需要 store 跟著換）；
/// `growthStore` 只留 `records`／`loadState`——見 `GrowthIdentityFreshnessRegressionTests`。
/// LS-335 起 `GrowthStore` 已收掉 `childName`／`childBirthday` 兩個屬性，結構上不會再讀到舊快照。
struct ChildGrowthDetailView: View {
    let child: Child
    let apiClient: GrowthAPIClient
    /// 非 nil 時 Identity Header 顯示「編輯」入口，推向這個閉包建出的畫面；nil 時（例如
    /// harness／`#Preview` 的獨立展示）不顯示這顆鈕。
    var editDestination: (() -> AnyView)?
    /// LS-313：03 記錄列表判斷「這筆是不是我的」（`GrowthRecord.authorID == currentUserID`）
    /// 才顯示「編輯」動作列——同 `ContentActions.swift` 的既有精神。nil＝視為「不是任何一筆的
    /// 作者」（例如尚未查到登入者身分時的保守預設）。
    var currentUserID: UUID?
    /// LS-313：owner 可以刪除（不能編輯）任何一筆，同「owner／作者權限沿 LS-57」——沿
    /// `ChildrenStore.isOwner` 既有慣例傳入，這支畫面本身不依賴 `ChildrenStore`。
    var isFamilyOwner = false
    /// R1 merge-review m3：`upsert_growth_record` 只允許 owner／member 寫入（`growth_records_
    /// insert` RLS）——viewer 按「新增量測」必得 `42501`。沿 `editDestination` 既有先例，
    /// 由呼叫端傳入 `childrenStore.canManageChildren`（同一組 owner／member 判斷），這支畫面
    /// 本身不依賴 `ChildrenStore`。
    var canManageChildren = false
    /// LS-345：Identity Header 頭像——同 `currentUserID`／`isFamilyOwner`／`canManageChildren`
    /// 既有先例，由呼叫端（`childDetail(for:)`）傳 `childrenStore.avatarURL(for: child)`，這支
    /// 畫面本身仍不依賴 `ChildrenStore`。nil（沒有頭像，或簽名還沒回來）時 `ChildAvatarView`
    /// 退回姓名縮寫圓——同 `child`／`currentUserID` 的新鮮度規則：呼叫端每次重繪都重新算一次，
    /// 換頭像存檔後不需要 pop／push 就會反映新值（見 `GrowthIdentityFreshnessRegressionTests`
    /// 檔頭「姓名／生日一律讀 child」的同一套機制，這裡是同一機制的頭像版）。
    var avatarURL: URL?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var growthStore: GrowthStore?
    @State private var selectedMetric: GrowthMetric = .height
    @State private var showsAddMeasurement = false
    /// LS-379：飲食圖鑑暫時入口用（見 `ChildGrowthDetailView+FoodBookDebugEntry.swift`）；不標 `private`，
    /// 跨檔 extension 要讀。
    @Environment(\.foodAPIClient) var foodAPIClient

    init(
        child: Child, apiClient: GrowthAPIClient, editDestination: (() -> AnyView)? = nil,
        currentUserID: UUID? = nil, isFamilyOwner: Bool = false, canManageChildren: Bool = false,
        avatarURL: URL? = nil
    ) {
        self.child = child
        self.apiClient = apiClient
        self.editDestination = editDestination
        self.currentUserID = currentUserID
        self.isFamilyOwner = isFamilyOwner
        self.canManageChildren = canManageChildren
        self.avatarURL = avatarURL
    }

    #if DEBUG
    /// harness／`#Preview` 專用：直接注入已種好資料的 store，不走一次 async
    /// `loadIfNeeded()`（假 client 固定回傳 `[]`，會把種好的示範資料覆蓋成空狀態）。
    ///
    /// LS-335：合成的 `Child` 姓名／生日改由這裡的參數帶入（預設值＝Notes 示範資料集 `G1tRP9`
    /// 陳小安、2025-04-20），不再向 store 借——`GrowthStore` 已不持有姓名／生日。
    init(
        previewGrowthStore store: GrowthStore, childName: String = "陳小安",
        childBirthday: Date = BirthdayFormat.date(fromWireString: "2025-04-20")!,
        editDestination: (() -> AnyView)? = nil,
        currentUserID: UUID? = nil, isFamilyOwner: Bool = false, canManageChildren: Bool = true,
        avatarURL: URL? = nil
    ) {
        self.child = Child(
            id: store.childID, name: childName, birthday: childBirthday,
            avatarURL: nil, deletedAt: nil, createdAt: Date()
        )
        self.apiClient = PreviewGrowthAPIClient()
        self.editDestination = editDestination
        self.currentUserID = currentUserID
        self.isFamilyOwner = isFamilyOwner
        self.canManageChildren = canManageChildren
        self.avatarURL = avatarURL
        self._growthStore = State(initialValue: store)
    }
    #endif

    /// Notes `LiJgw`（04 AX3）：「Empty Message topMargin 110、plotH 340 避免文字擠壓」——
    /// AX3 空狀態文案（含孩子名字，最長可能三行）需要比一般字級更高的繪圖區，否則會跟
    /// 「月齡」軸名擠在一起（R1 模擬器實測抓到的視覺缺陷）。populated 態不受影響（真的有
    /// 資料時骨架版不會渲染）。
    private var chartPlotHeight: CGFloat {
        guard horizontalSizeClass != .regular else { return 320 }
        return dynamicTypeSize >= .accessibility3 ? 340 : 220
    }

    var body: some View {
        Group {
            if let growthStore, growthStore.childID == child.id {
                content(growthStore)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(horizontalSizeClass == .regular ? "" : child.name)
        .navigationBarTitleDisplayMode(horizontalSizeClass == .regular ? .inline : .large)
        .task(id: child.id) {
            await loadIfNeeded()
        }
        .sheet(isPresented: $showsAddMeasurement) {
            // LS-313：`showsAddMeasurement` 只在 `actionsCompact`／`regularLayout`（`content(_:)`
            // 底下已解開 `growthStore` 的分支）才會被設成 `true`，這裡的 `growthStore` 理論上
            // 一定非 nil；`if let` 純粹是為了在極端時序（sheet 呈現動畫期間 `child.id` 剛好變
            // 而觸發 `.task(id:)` 重建 store）下不 force-unwrap 崩潰，不是期待常態走到 else。
            if let growthStore {
                GrowthMeasurementFormView(growthStore: growthStore)
            }
        }
    }

    @MainActor
    private func loadIfNeeded() async {
        guard GrowthStore.needsRebuild(current: growthStore, forChildID: child.id) else { return }
        let store = GrowthStore(childID: child.id, apiClient: apiClient)
        growthStore = store
        await store.refresh()
    }

    /// m1（merge-review R2，orchestrator 裁決）：首次載入（`.submitting`＋還沒有任何資料）不能
    /// 誤呈現成 04「這張紙還沒有記錄」——同 `AlbumDetailView.photoGridOrEmptyState` 既有語彙
    /// （`case .submitting where store.photos.isEmpty: ProgressView()`），冷啟動／慢網時使用者
    /// 不會盯著空狀態文案、誤按「新增量測」。有資料之後即使背景重新整理（`.submitting`
    /// 但 `!isEmpty`）仍照常渲染舊資料，不切回骨架版。
    @ViewBuilder
    private func content(_ growthStore: GrowthStore) -> some View {
        if case .submitting = growthStore.loadState, growthStore.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if horizontalSizeClass == .regular {
            regularLayout(growthStore)
        } else {
            compactLayout(growthStore)
        }
    }

    // MARK: - Compact (iPhone) — 01／04

    private func compactLayout(_ growthStore: GrowthStore) -> some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                identityHeader()
                VStack(alignment: .leading, spacing: AppSpacing.item) {
                    Text("最新紀錄")
                        .appFont(.body)
                        .foregroundStyle(Color.lsTextPrimary)
                    latestValuesRow(growthStore)
                }
                failureBanner(growthStore)
                GrowthChartCardView(
                    titleFont: .body, metric: $selectedMetric,
                    points: growthStore.curvePoints(for: selectedMetric, birthday: child.birthday),
                    isEmptyState: growthStore.isEmpty, childName: child.name,
                    plotHeight: chartPlotHeight
                )
                actionsCompact(growthStore)
                foodBookDebugEntry()
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
            .padding(.bottom, AppSpacing.item)
        }
        .appBackground()
    }

    private func actionsCompact(_ growthStore: GrowthStore) -> some View {
        VStack(spacing: AppSpacing.group) {
            if canManageChildren {
                PrimaryButton(icon: "plus", title: "新增量測") {
                    showsAddMeasurement = true
                }
            }
            NavigationLink {
                GrowthRecordsListView(
                    growthStore: growthStore, childName: child.name,
                    currentUserID: currentUserID, isFamilyOwner: isFamilyOwner
                )
            } label: {
                Text("查看全部紀錄")
                    .appFont(.body, weight: .medium)
                    .foregroundStyle(Color.lsTextPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
            }
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
            )
        }
    }

    // MARK: - Regular (iPad) — 06

    /// 只負責 Content Pane 本身的內容——左側 Nav Sidebar（時間軸／相簿／寶貝／設定）是
    /// `RootView.SectionSplitView` 既有的 app 層 iPad 殼（見該檔），不是這張票的範圍，這裡
    /// 不重畫一份。
    private func regularLayout(_ growthStore: GrowthStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                identityHeader()
                failureBanner(growthStore)
                GrowthChartCardView(
                    titleFont: .lead, metric: $selectedMetric,
                    points: growthStore.curvePoints(for: selectedMetric, birthday: child.birthday),
                    isEmptyState: growthStore.isEmpty, childName: child.name,
                    plotHeight: chartPlotHeight
                )
                VStack(alignment: .leading, spacing: AppSpacing.item) {
                    Text("最新紀錄")
                        .appFont(.body)
                        .foregroundStyle(Color.lsTextPrimary)
                    latestValuesRow(growthStore)
                }
                if canManageChildren {
                    PrimaryButton(icon: "plus", title: "新增量測") {
                        showsAddMeasurement = true
                    }
                }
                if !growthStore.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.item) {
                        HStack {
                            Text("歷史紀錄")
                                .appFont(.body)
                                .foregroundStyle(Color.lsTextPrimary)
                            Spacer(minLength: 0)
                            // R1 merge-review i1：06 之前完全沒有編輯／刪除路徑——
                            // `GrowthHistorySection` 是純顯示，打錯的紀錄永遠改不了。沿用同一
                            // 支 03 列表 View（同 compact 版的「查看全部紀錄」入口），不另畫
                            // 新版面。
                            NavigationLink {
                                GrowthRecordsListView(
                                    growthStore: growthStore, childName: child.name,
                                    currentUserID: currentUserID, isFamilyOwner: isFamilyOwner
                                )
                            } label: {
                                Text("查看全部紀錄")
                                    .appFont(.body, weight: .semibold)
                                    .foregroundStyle(Color.lsAccent)
                                    .frame(minHeight: 44)
                            }
                        }
                        GrowthHistorySection(records: growthStore.records)
                    }
                }
                foodBookDebugEntry()
            }
            .padding(.horizontal, AppSpacing.screenPadLarge)
            .padding(.top, AppSpacing.item)
            .padding(.bottom, AppSpacing.block)
        }
        .appBackground()
    }

    // MARK: - 共用

    /// M2（merge-review R1，orchestrator 裁決）：讀取失敗（離線／token 過期／伺服器 5xx）不能
    /// 被 `isEmpty` 靜默吞成 04 空狀態——同 `AlbumDetailView.loadFailureState` 既有語彙
    /// （錯誤文案＋「重新載入」），疊在骨架卡上方。`重新載入` 直接呼叫 `refresh()`——
    /// `GrowthStore.refresh()` 本身的 `!loadState.isSubmitting` guard 已防重入，不需要另外
    /// disable 這顆按鈕。
    @ViewBuilder
    private func failureBanner(_ growthStore: GrowthStore) -> some View {
        if case .failure(let error) = growthStore.loadState {
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                Text(error.userFacingMessage).appFont(.note)
                Spacer(minLength: 0)
                Button {
                    Task { await growthStore.refresh() }
                } label: {
                    Text("重新載入")
                        .appFont(.body, weight: .semibold)
                        .frame(minHeight: 48)
                }
            }
            .foregroundStyle(Color.lsTextPrimary)
        }
    }

    /// m2（merge-review R2，orchestrator 裁決）：年齡字串套 `AlbumSignatureFormatter.
    /// hardenedAge(_:)`（NBSP／WORD JOINER）——稿面 `jp6ka`／`pjrd7` 這處 codepoint 是不斷行
    /// 空白（同 LS-309 `design_identity_header_check.py` 驗的形狀），長字串（例如「11 歲 11
    /// 個月」）＋AX3＋iPhone 窄欄時才不會斷成「…個」／「月」孤字。刻意不改 `BirthdayFormat`
    /// 本體——那支還餵著 `childRowContent` 的 `Pill` 等既有畫面，會擴散到票外。
    private func identityHeader() -> some View {
        HStack(spacing: AppSpacing.group) {
            ChildAvatarView(name: child.name, size: 64, avatarURL: avatarURL)
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                Text(child.name)
                    .appFont(.display, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                Text(AlbumSignatureFormatter.hardenedAge(BirthdayFormat.ageDescription(birthday: child.birthday)))
                    .appFont(.body)
                    .foregroundStyle(Color.lsTextSecondary)
            }
            Spacer(minLength: 0)
            if let editDestination {
                NavigationLink {
                    editDestination()
                } label: {
                    Text("編輯")
                        .appFont(.body, weight: .semibold)
                        .foregroundStyle(Color.lsTextPrimary)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }

    /// QA `49c96b88`（FAIL）：這裡原本從頭到尾是固定 `HStack`，AX3 下三格擠在窄欄裡把數字
    /// 逐字元拆行。Notes `a9S6ke`（AX3）「Latest Values」節點 `TAbxe` 是 `layout: vertical`
    /// （對比一般字級板 `jp6ka` 的 `iYQf1` 為橫向），沿用同檔 `GrowthSegmentedControl.
    /// isVerticalLayout` 既有分支寫法：AX3 改三格上下堆疊、gap 抄 `$sp-item`
    /// （`AppSpacing.item`）；一般字級維持原本橫向、gap 不變。
    private func latestValuesRow(_ growthStore: GrowthStore) -> some View {
        Group {
            if dynamicTypeSize >= .accessibility3 {
                VStack(spacing: AppSpacing.item) { latestValueCards(growthStore) }
            } else {
                HStack(spacing: AppSpacing.group) { latestValueCards(growthStore) }
            }
        }
    }

    private func latestValueCards(_ growthStore: GrowthStore) -> some View {
        ForEach(GrowthMetric.allCases) { metric in
            GrowthLatestValueCard(metric: metric, latest: growthStore.latestValue(for: metric))
        }
    }
}

#if DEBUG
#Preview("01 有資料") {
    NavigationStack {
        ChildGrowthDetailView(
            previewGrowthStore: .previewSeededWithDemoRecords(),
            currentUserID: GrowthStore.previewAuthorID, isFamilyOwner: true
        )
    }
}

#Preview("04 空狀態") {
    NavigationStack {
        ChildGrowthDetailView(previewGrowthStore: .preview(), childName: "陳小軒")
    }
}
#endif

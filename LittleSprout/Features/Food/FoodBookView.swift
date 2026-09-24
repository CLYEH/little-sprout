import SwiftUI

/// 一格被點到時交給呼叫端的資訊：還沒吃（開第一次記錄 sheet，LS-380）／吃過（開記錄詳情，LS-381）。
enum FoodBookSelection: Equatable {
    case untried(FoodCatalogItem)
    case tried(FoodCatalogItem, ChildFoodRecord)
}

/// 飲食圖鑑 02（LS-379，`design/littlesprout.pen` `hWu6N`〔iPhone〕／`XuCDh`〔深色〕／`x3aELx`〔AX3〕／
/// `oFpsV`〔iPad〕／`SYefI`〔02b 乳製品一歲後標記〕／`jo5h8`〔02c viewer 唯讀〕）。
///
/// 畫面級屬性（Notes `jyt14` 02／02b／02c 三列，逐條落地）：
/// - 隱藏 Tab Bar ✗（一般 push，不呼叫 `.toolbar(.hidden, for: .tabBar)`）。
/// - 標題「自訂 display『飲食圖鑑』＋Nav Back『陳小安』」：標題由 body 的 `header` 以 `$fs-display` 畫；
///   系統 nav bar 只留返回鍵（上一頁寶貝詳情的標題＝孩子名，系統自動當返回鍵文字）——`.inline`＋
///   零尺寸 principal 關掉系統標題（同 `TimelineView`／`ChildrenManagementView+Regular` 既有手法），
///   `.navigationTitle("飲食圖鑑")` 仍保留，讓下一層（記錄詳情 04，Nav Back「飲食圖鑑」）的返回鍵文字對。
/// - 釘底動作帶：無。
/// - 失敗文案鍵 42501：讀取失敗一律走 `AppError.userFacingMessage`（同 `ChildGrowthDetailView.failureBanner`），
///   首次載入失敗整頁換成錯誤態＋「重新載入」；已有資料時重新整理失敗則資料保留、上方加一條錯誤列。
/// - 深色：token 自動（紙不反轉由 `print-paper`／`print-ink` token 本身保證），不另寫分支。
/// - AX3：分頁 4×2、格子改單欄橫排清單（`FoodCell.Layout.list`）、類別標題與「吃過 N／M」上下排——
///   門檻用 `dynamicTypeSize.isAccessibilitySize`（AX1 起）：稿面只畫 AX3，AX1／AX2 下 3 欄格子一格只剩
///   約 92pt 寬、四字食物名會逐字折行，比照 AX3 規則處理。
/// - iPad（regular）：4 欄、左右 `$screen-pad-lg`（40）、分頁欄距 8；左側 Nav Sidebar 是
///   `RootView.SectionSplitView` 既有外殼，不在這裡重畫（同 `ChildGrowthDetailView.regularLayout`）。
/// - 資料落點：分頁＝純 UI 狀態（不持久化）；格子狀態＝`child_food_records.food_id` 是否存在。
///
/// 目的地（本票先接 placeholder）：點還沒吃的格子開第一次記錄 sheet（LS-380）、點吃過的格子推記錄詳情
/// （LS-381）。兩者都可由呼叫端注入（`firstRecordDestination`／`recordDetailDestination`），另有
/// `onSelect` 回呼讓呼叫端在呈現之外做事（例如 LS-380 的「收下」動效要知道剛點的是哪一格）。
struct FoodBookView: View {
    let child: Child
    let apiClient: FoodAPIClient
    /// owner／member＝true（可新增記錄）；viewer＝false（02c：空位不是按鈕、提示句換成唯讀版）。
    let canRecord: Bool
    var onSelect: ((FoodBookSelection) -> Void)?
    var firstRecordDestination: ((FoodCatalogItem) -> AnyView)?
    var recordDetailDestination: ((FoodCatalogItem, ChildFoodRecord) -> AnyView)?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var store: FoodBookStore?
    @State private var selectedCategory: FoodCategory
    @State private var firstRecordItem: FoodCatalogItem?
    @State private var detailRecord: ChildFoodRecord?

    init(
        child: Child, apiClient: FoodAPIClient, canRecord: Bool, initialCategory: FoodCategory = .grainRoot,
        onSelect: ((FoodBookSelection) -> Void)? = nil,
        firstRecordDestination: ((FoodCatalogItem) -> AnyView)? = nil,
        recordDetailDestination: ((FoodCatalogItem, ChildFoodRecord) -> AnyView)? = nil
    ) {
        self.child = child
        self.apiClient = apiClient
        self.canRecord = canRecord
        self.onSelect = onSelect
        self.firstRecordDestination = firstRecordDestination
        self.recordDetailDestination = recordDetailDestination
        _selectedCategory = State(initialValue: initialCategory)
    }

    #if DEBUG
    /// harness／`#Preview` 專用：直接注入已種好資料的 store（同 `ChildGrowthDetailView(previewGrowthStore:)`）。
    init(
        previewStore: FoodBookStore, childName: String = "陳小安", canRecord: Bool = true,
        initialCategory: FoodCategory = .grainRoot
    ) {
        self.child = Child(
            id: previewStore.childID, name: childName,
            birthday: BirthdayFormat.date(fromWireString: "2025-04-20")!, avatarURL: nil, deletedAt: nil,
            createdAt: Date()
        )
        self.apiClient = PreviewFoodAPIClient()
        self.canRecord = canRecord
        _selectedCategory = State(initialValue: initialCategory)
        _store = State(initialValue: previewStore)
    }
    #endif

    var body: some View {
        Group {
            if let store, store.childID == child.id {
                content(store)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .appBackground()
        .navigationTitle("飲食圖鑑")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 0, height: 0).accessibilityHidden(true) }
        }
        .task(id: child.id) { await loadIfNeeded() }
        .sheet(item: $firstRecordItem) { item in
            firstRecordDestination?(item) ?? AnyView(FoodBookPendingDestination(item: item, ticket: "LS-380"))
        }
        .navigationDestination(item: $detailRecord) { record in
            if let item = store?.catalog.first(where: { $0.id == record.foodID }) {
                recordDetailDestination?(item, record)
                    ?? AnyView(FoodBookPendingDestination(item: item, ticket: "LS-381"))
            }
        }
    }

    @MainActor
    private func loadIfNeeded() async {
        guard FoodBookStore.needsRebuild(current: store, forChildID: child.id) else { return }
        let newStore = FoodBookStore(childID: child.id, apiClient: apiClient)
        store = newStore
        await newStore.refresh()
    }

    private var isAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    private var isRegular: Bool { horizontalSizeClass == .regular }

    @ViewBuilder
    private func content(_ store: FoodBookStore) -> some View {
        if store.catalog.isEmpty {
            if case .failure(let error) = store.loadState {
                loadFailure(message: error.userFacingMessage, store: store)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.section) {
                    header(store)
                    VStack(alignment: .leading, spacing: AppSpacing.block) {
                        refreshFailureBanner(store)
                        FoodCategoryTabs(
                            selection: $selectedCategory,
                            columns: isAccessibilityLayout ? 2 : 4,
                            columnSpacing: isRegular || isAccessibilityLayout ? AppSpacing.label : AppSpacing.tight
                        )
                        collection(store)
                        disclaimer
                    }
                }
                .padding(.top, AppSpacing.item)
                .padding(.horizontal, isRegular ? AppSpacing.screenPadLarge : AppSpacing.screenPad)
                .padding(.bottom, AppSpacing.section)
            }
        }
    }

    private func header(_ store: FoodBookStore) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("飲食圖鑑")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(FoodBookCopy.progressSentence(
                childName: child.name, triedCount: store.triedCount, totalCount: store.totalCount
            ))
            .appFont(.body)
            .foregroundStyle(Color.lsTextSecondary)
            .accessibilityIdentifier("foodBook.progress")
        }
    }

    private func collection(_ store: FoodBookStore) -> some View {
        let items = store.items(in: selectedCategory)
        return VStack(alignment: .leading, spacing: AppSpacing.item) {
            categoryHead(triedCount: store.triedCount(in: selectedCategory), totalCount: items.count)
            if isAccessibilityLayout {
                LazyVStack(spacing: AppSpacing.item) {
                    ForEach(items) { item in cell(item, store: store, layout: .list) }
                }
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: AppSpacing.item, alignment: .top),
                        count: isRegular ? 4 : 3
                    ),
                    spacing: AppSpacing.item
                ) {
                    ForEach(items) { item in cell(item, store: store, layout: .grid) }
                }
            }
        }
    }

    private func categoryHead(triedCount: Int, totalCount: Int) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            let title = Text(selectedCategory.displayName)
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .accessibilityAddTraits(.isHeader)
            let count = Text(FoodBookCopy.categoryCount(triedCount: triedCount, totalCount: totalCount))
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextSecondary)
                .accessibilityIdentifier("foodBook.categoryCount")
            if isAccessibilityLayout {
                VStack(alignment: .leading, spacing: AppSpacing.tight) { title; count }
            } else {
                HStack(alignment: .lastTextBaseline) { title; Spacer(minLength: AppSpacing.label); count }
            }
            Text(FoodBookCopy.tapHint(canRecord: canRecord))
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private func cell(_ item: FoodCatalogItem, store: FoodBookStore, layout: FoodCell.Layout) -> some View {
        let record = store.record(for: item.id)
        return FoodCell(item: item, state: FoodCellState.make(record: record, canRecord: canRecord), layout: layout) {
            select(item, record: record)
        }
    }

    private func select(_ item: FoodCatalogItem, record: ChildFoodRecord?) {
        if let record {
            onSelect?(.tried(item, record))
            detailRecord = record
        } else {
            onSelect?(.untried(item))
            firstRecordItem = item
        }
    }

    /// 免責句（02 Disclaimer `xLX8T`）：info 圖示＋一句，固定排在格子之後。
    private var disclaimer: some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "info.circle").appIconFrame(.small)
            Text(FoodBookCopy.disclaimer)
                .appFont(.note)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Color.lsTextSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("foodBook.disclaimer")
    }
}

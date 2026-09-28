import SwiftUI

/// 寶貝詳情「飲食圖鑑」入口區塊（LS-382，`design/littlesprout.pen` 01 `QRoGt`〔iPhone〕／`LNHXU`〔深色〕／
/// `BSWDH`〔A11y/01 AX3〕／`h5PBGH`〔01-iPad〕；01b `J58vyP`＋`wcpNj`〔0 筆〕；01c `ls2g6`〔1 筆〕），排在
/// `ChildGrowthDetailView`「成長」區塊之後。
///
/// 畫面級屬性（Notes `jyt14` 01／01b／01c 三列 `KqOZI`／`wM6SX`／`qd7nA`）：隱藏 Tab Bar ✗、標題系統 large、
/// 釘底動作帶無——三項都屬宿主 `ChildGrowthDetailView`，本區塊不動；失敗文案鍵 42501：首次讀取失敗時計數句
/// 位置換成 `AppError.userFacingMessage`＋「重新載入」（同 `FoodBookView.refreshFailureBanner` 語彙）；深色 token
/// 自動；AX（`isAccessibilitySize`，門檻同 `FoodBookView`）改 `FoodCell.Layout.list` 直排、次要鈕短文案；
/// iPad（regular）五格、標題與內容間距 `$sp-section`（01-iPad `Food Lead`／`Food Block` 是 Content Pane 的
/// 兩個子節點）。
///
/// **三態等高**（Notes `h752D`「01 與 01b 同高 1483、按鈕不位移」）：格子數固定（`FoodBookEntry.slots` 不足就補
/// 空位）；每格小標恰好一列（`tagLines: 1`——沒有就補空白、兩個只留過敏原，見 `FoodCell.visibleTags`）；一列格子
/// 取最高那格的高度（`fixedSize(vertical:)`＋`FoodCell` 自己的 `maxHeight: .infinity`）。
///
/// **store 共用**：`store` 由宿主（每個寶貝一顆，`FoodBookStore.needsRebuild`）建好傳入，推圖鑑時把同一顆交給
/// `FoodBookView`——圖鑑或詳情頁裡的儲存／刪除（`applySaved`／`removeRecord`）返回時入口三格已是新的，不必重抓。
///
/// 目的地：空位開第一次記錄 sheet（`FoodRecordSheet`，同 LS-380 起點 02 的呼叫方式），`onDismiss` 後播「收下」
/// 動效（06 `jIWO6`，起點 01：`scrollTo(anchor: .center)`；剛存那筆若因回填日期較早落到格子之外就不播，只更新
/// 計數，Notes `cEkCH`）；吃過的格子推記錄詳情（`FoodRecordDetailRouter`）；次要鈕推整本圖鑑。
struct FoodBookEntrySection: View {
    let child: Child
    let store: FoodBookStore
    let apiClient: FoodAPIClient
    /// owner／member＝true；viewer＝false（空位不是按鈕，同 02c）。
    let canRecord: Bool
    let recordDetailContext: FoodRecordDetailContext

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var firstRecordItem: FoodCatalogItem?
    @State private var detailRecord: ChildFoodRecord?
    /// 剛儲存、還沒播「收下」的那一格（sheet 收起前維持「還沒吃」的外觀，同 `FoodBookView`）。
    @State private var pendingRevealFoodID: String?
    @State private var revealRequest: String?
    @State private var revealCount = 0

    private var isRegular: Bool { horizontalSizeClass == .regular }
    private var isAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    private var slotCount: Int { isRegular ? FoodBookEntry.regularSlotCount : FoodBookEntry.compactSlotCount }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: isRegular ? AppSpacing.section : AppSpacing.item) {
                Text("飲食圖鑑")
                    .appFont(.body, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("foodEntry.title")
                content
            }
            .onChange(of: revealRequest) { _, foodID in
                guard let foodID else { return }
                revealRequest = nil
                playReveal(foodID, proxy: proxy)
            }
        }
        .sheet(
            item: $firstRecordItem,
            onDismiss: { revealRequest = pendingRevealFoodID },
            content: firstRecordSheet
        )
        .sensoryFeedback(.impact(weight: .light), trigger: revealCount)
        .navigationDestination(item: $detailRecord) { record in
            if let item = store.catalog.first(where: { $0.id == record.foodID }) {
                recordDetail(item, record)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.catalog.isEmpty {
            if case .failure(let error) = store.loadState {
                loadFailure(message: error.userFacingMessage)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 48)
            }
        } else {
            let slots = FoodBookEntry.slots(catalog: store.catalog, records: store.records, count: slotCount)
            VStack(alignment: .leading, spacing: AppSpacing.item) {
                Text(FoodBookEntry.countLine(
                    childName: child.name, triedCount: store.triedCount, totalCount: store.totalCount, slots: slots
                ))
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("foodEntry.countLine")
                cells(slots)
                bookButton
            }
        }
    }

    @ViewBuilder
    private func cells(_ slots: [FoodBookEntrySlot]) -> some View {
        if isAccessibilityLayout {
            VStack(spacing: AppSpacing.item) {
                ForEach(slots) { cell($0, layout: .list) }
            }
        } else {
            HStack(alignment: .top, spacing: AppSpacing.item) {
                ForEach(slots) { cell($0, layout: .grid) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cell(_ slot: FoodBookEntrySlot, layout: FoodCell.Layout) -> some View {
        let isHeldForReveal = pendingRevealFoodID == slot.item.id
        let state = FoodCellState.make(record: isHeldForReveal ? nil : slot.record, canRecord: canRecord)
        return FoodCell(item: slot.item, state: state, layout: layout, tagLines: 1) {
            if let record = slot.record {
                detailRecord = record
            } else {
                firstRecordItem = slot.item
            }
        }
        .offset(y: isHeldForReveal ? FoodRevealMotion.spec(reduceMotion: reduceMotion).startOffsetY : 0)
        .id(slot.item.id)
    }

    private var bookButton: some View {
        NavigationLink {
            FoodBookView(
                child: child, apiClient: apiClient, canRecord: canRecord, store: store,
                recordDetailContext: recordDetailContext
            )
        } label: {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "book").appIconFrame(.medium)
                Text(FoodBookEntry.bookButtonTitle(
                    triedCount: store.triedCount, isAccessibilityLayout: isAccessibilityLayout
                ))
                .appFont(.body, weight: .semibold)
            }
            .foregroundStyle(Color.lsTextPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .padding(.horizontal, 20)
            .contentShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
        )
        .accessibilityIdentifier("foodEntry.openBook")
    }

    /// 首次讀取就失敗（沒有任何資料）：計數句位置換成錯誤句＋「重新載入」——不落回全灰的三格，那會讓人以為
    /// 孩子什麼都沒吃過（同 `FoodBookView.loadFailure` 的理由）。`refresh()` 自己以 `isLoading` 防重入。
    private func loadFailure(message: String) -> some View {
        HStack(spacing: AppSpacing.tight) {
            Image(systemName: "exclamationmark.circle").appIconFrame(.small)
            Text(message).appFont(.note)
            Spacer(minLength: 0)
            Button {
                Task { await store.refresh() }
            } label: {
                Text("重新載入")
                    .appFont(.body, weight: .semibold)
                    .frame(minHeight: 48)
            }
            .accessibilityIdentifier("foodEntry.reload")
        }
        .foregroundStyle(Color.lsTextPrimary)
    }

    private func firstRecordSheet(_ item: FoodCatalogItem) -> some View {
        FoodRecordSheet(
            childName: child.name,
            store: FoodRecordEditorStore(childID: child.id, item: item, apiClient: apiClient),
            apiClient: apiClient,
            onSaved: { record in
                // 同一個 transaction 內先按住、再套用：那一格不會先閃成紙片再被按回灰色（同 `FoodBookView`）。
                pendingRevealFoodID = record.foodID
                store.applySaved(record)
            }
        )
    }

    /// 詳情頁一律拿 store 裡最新的那一筆（同 `FoodBookView.recordDetail`）：03b 存檔後換新、刪除後格子退回未吃並返回。
    private func recordDetail(_ item: FoodCatalogItem, _ record: ChildFoodRecord) -> some View {
        let latest = store.record(for: record.foodID).flatMap { $0.id == record.id ? $0 : nil } ?? record
        return FoodRecordDetailRouter(
            child: child, item: item, record: latest, apiClient: apiClient, context: recordDetailContext,
            canRecord: canRecord,
            onSaved: { store.applySaved($0) },
            onRemoved: { id in
                store.removeRecord(id: id)
                detailRecord = nil
            }
        )
    }

    /// 06 起點 01：剛存那筆若在目前的格子裡，捲到中央再以 `FoodRevealMotion` 放開；不在（回填日期較早、排到
    /// 格子之外）就直接放開、不播動效（Notes `cEkCH`「則不播，只更新計數」）。VoiceOver 兩種情況都唸「已記下〇〇」
    /// ——那是儲存成功的回饋，不是動效本身。
    private func playReveal(_ foodID: String, proxy: ScrollViewProxy) {
        let slots = FoodBookEntry.slots(catalog: store.catalog, records: store.records, count: slotCount)
        if slots.contains(where: { $0.item.id == foodID }) {
            proxy.scrollTo(foodID, anchor: .center)
            withAnimation(FoodRevealMotion.animation(reduceMotion: reduceMotion)) { pendingRevealFoodID = nil }
            revealCount += 1
        } else {
            pendingRevealFoodID = nil
        }
        if let name = store.catalog.first(where: { $0.id == foodID })?.nameZh {
            AccessibilityNotification.Announcement(FoodRecordCopy.revealAnnouncement(foodName: name)).post()
        }
    }
}

import SwiftUI

/// 飲食圖鑑 04 記錄詳情（LS-381，`design/littlesprout.pen` `B8krzV`〔有照片〕／`ygv7k`〔深色〕／`z1Pg2`〔AX3〕／
/// `orGax`〔iPad〕／`gIo3O`〔04b 無照片〕／`vr5zj`〔04b AX3〕／`GRB0y`〔04b 深色〕／`Z8zWzZ`〔04c 非作者 owner〕）。
///
/// 內容順序（稿面 Body `tYdzx`）：Head Group（貼紙＋食物名／類別 → 旋轉日期章）→ Memory Group（沖印品照片
/// → 反應／一句話／記錄者 → 過敏原 info 句）→ 動作鈕（依權限三態，見 `FoodRecordDetailCopy.actions`）。
///
/// 畫面級屬性（Notes `jyt14` 04 `B2HPfk`／04b `xFvkL`／04c `Iu1VD` 三列，逐條落地）：
/// - 隱藏 Tab Bar ✗（一般 push，不呼叫 `.toolbar(.hidden, for: .tabBar)`）。
/// - 標題「自訂 display 食物名＋Nav Back『飲食圖鑑』」：食物名由 body 以 `$fs-display` 畫；系統 nav bar 只留
///   返回鍵（上一頁 `FoodBookView` 的 `.navigationTitle("飲食圖鑑")` 就是返回鍵文字）——`.inline`＋零尺寸
///   principal 關掉系統標題（同 `FoodBookView`）。
/// - 釘底動作帶：無（動作鈕隨內容捲動）。
/// - 失敗文案鍵 42501（04c 另有 LS052／LS053，屬刪除 sheet，LS-380）：重讀失敗走
///   `AppError.userFacingMessage`，內容保留、上方加一條錯誤列＋「重新載入」（同 `FoodBookView.refreshFailureBanner`）。
/// - 深色：token 自動（紙不反轉由 `print-paper`／`print-ink` token 本身保證），不另寫分支。
/// - AX3（`dynamicTypeSize.isAccessibilitySize`，同 `FoodBookView` 門檻）：貼紙與食物名直排、日期章兩行且改
///   `$fs-note`（稿 `BwfLB`）。
/// - iPad（regular）：貼紙 120、左右 `$screen-pad-lg`、照片 274×350 的沖印品（寬 290）與反應欄左右並排
///   （稿 `TkCHZ` Memory Row）；左側 Nav Sidebar 是 `RootView.SectionSplitView` 既有外殼。
/// - 資料落點：唯讀；編輯（僅作者）開 03b、刪除（非作者 owner）開 03c、04b 空白沖印品開照片來源——三者皆
///   LS-380 的 sheet，本票只經 `onRoute` 交出去（見 `FoodRecordDetailRoute`）。
///
/// 記錄開著時被刪（owner 刪了別人的、作者在另一台裝置刪了）：`FoodRecordDetailStore.refresh()` 重讀發現這筆
/// 不在了（`isGone`）就返回圖鑑，不停在一筆已不存在的記錄上。
struct FoodRecordDetailView: View {
    let child: Child
    let item: FoodCatalogItem
    let record: ChildFoodRecord
    let apiClient: FoodAPIClient
    /// 目前登入者（`familyStore.ownerUserID`，命名見 `ChildrenManagementView+Detail` 註解）；nil＝不是任何一筆的作者。
    let currentUserID: UUID?
    let isFamilyOwner: Bool
    /// owner／member＝true（`ChildrenStore.canManageChildren`）；viewer＝false。
    let canRecord: Bool
    /// 編輯／刪除／加照片交給呼叫端開 sheet（LS-380，`FoodRecordDetailRouter`）。
    var onRoute: (FoodRecordDetailRoute) -> Void
    /// 重讀發現這筆已被刪（`isGone`）：非 nil＝交給呼叫端（圖鑑把格子退回未吃並 pop，LS-380 接縫④）；
    /// nil＝自己 `dismiss()`（harness／preview 等沒有圖鑑 store 的呼叫端）。
    var onGone: ((UUID) -> Void)?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.foodRecordDetailAPIClient) private var environmentDetailAPIClient
    @State private var store: FoodRecordDetailStore?
    private let detailAPIClientOverride: (any FoodRecordDetailAPIClient)?

    init(
        child: Child, item: FoodCatalogItem, record: ChildFoodRecord, apiClient: FoodAPIClient,
        currentUserID: UUID?, isFamilyOwner: Bool, canRecord: Bool,
        detailAPIClient: (any FoodRecordDetailAPIClient)? = nil,
        onGone: ((UUID) -> Void)? = nil,
        // 正式呼叫端（`FoodRecordDetailRouter`）接 03b／03c／照片來源 sheet；harness 單獨展示詳情頁時用預設 no-op。
        onRoute: @escaping (FoodRecordDetailRoute) -> Void = { _ in }
    ) {
        self.child = child
        self.item = item
        self.record = record
        self.apiClient = apiClient
        self.currentUserID = currentUserID
        self.isFamilyOwner = isFamilyOwner
        self.canRecord = canRecord
        self.detailAPIClientOverride = detailAPIClient
        self.onRoute = onRoute
        self.onGone = onGone
    }

    private var isAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    private var isRegular: Bool { horizontalSizeClass == .regular }
    /// store 建好之前（第一幀）直接用呼叫端帶進來的那一筆，不閃 ProgressView。
    private var shown: ChildFoodRecord { store?.record ?? record }
    private var actions: [FoodRecordDetailAction] {
        FoodRecordDetailCopy.actions(
            authorID: shown.authorID, currentUserID: currentUserID, isFamilyOwner: isFamilyOwner, canRecord: canRecord
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.item) {
                refreshFailureBanner
                VStack(alignment: .leading, spacing: AppSpacing.section) {
                    headGroup
                    if isRegular { memoryRow } else { memoryGroup }
                    actionButtons
                }
            }
            .padding(.top, AppSpacing.item)
            .padding(.horizontal, isRegular ? AppSpacing.screenPadLarge : AppSpacing.screenPad)
            .padding(.bottom, AppSpacing.section)
        }
        .appBackground()
        .navigationTitle(item.nameZh)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 0, height: 0).accessibilityHidden(true) }
        }
        // LS-380 接縫⑦：以整筆記錄（含 `updatedAt`）當 key——03b 儲存後圖鑑套用回傳列、呼叫端帶進更新過的
        // 那筆，這裡就重跑：同一筆 id 保留 store、先換上新值再重讀（見 `FoodRecordDetailStore.adopt`）。
        .task(id: record) { await loadIfNeeded() }
        .onChange(of: store?.isGone == true) { _, isGone in
            guard isGone else { return }
            if let onGone { onGone(record.id) } else { dismiss() }
        }
    }

    @MainActor
    private func loadIfNeeded() async {
        if store?.record.id != record.id {
            store = FoodRecordDetailStore(
                record: record, foodAPIClient: apiClient,
                detailAPIClient: detailAPIClientOverride ?? environmentDetailAPIClient
            )
        } else {
            store?.adopt(record)
        }
        await store?.refresh()
    }

    // MARK: - Head Group（`i2oMD`）

    private var headGroup: some View {
        VStack(alignment: .leading, spacing: AppSpacing.item) {
            identity
            FoodFirstTriedStamp(firstTriedOn: shown.firstTriedOn, isAccessibilityLayout: isAccessibilityLayout)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
        }
    }

    /// Food Identity（`zHcDG`）：貼紙 96（iPad 120）＋食物名 `$fs-display` 700／類別 `$fs-body` `$text-secondary`；
    /// AX3 直排（`v63xG`，gap `$sp-label`）。
    @ViewBuilder
    private var identity: some View {
        let sticker = FoodStickerImage(foodID: item.id, size: isRegular ? 120 : 96, isGrayscale: false)
        let texts = VStack(alignment: .leading, spacing: AppSpacing.tight) {
            Text(item.nameZh)
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("foodRecordDetail.title")
            Text(item.category.displayName)
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if isAccessibilityLayout {
            VStack(alignment: .leading, spacing: AppSpacing.label) { sticker; texts }
        } else {
            HStack(spacing: AppSpacing.item) { sticker; texts }
        }
    }

    // MARK: - Memory Group（`WrOko`）／iPad Memory Row（`TkCHZ`）

    private var photoState: FoodRecordDetailPhotoState {
        store?.photo ?? (shown.mediaID == nil ? .none : .loading)
    }

    private var photoPrint: some View {
        FoodRecordPrint(
            photo: photoState,
            photoHeight: isRegular ? 350 : 400,
            caption: FoodRecordDetailCopy.imprintCaption(child: child, firstTriedOn: shown.firstTriedOn),
            mountPool: isRegular ? .regular : .compact,
            addPhotoLabel: FoodRecordDetailCopy.addPhotoLabel(foodName: item.nameZh),
            onAddPhoto: actions.contains(.edit) ? { onRoute(.addPhoto(shown)) } : nil,
            onRetryPhoto: { Task { await store?.retryPhoto() } }
        )
    }

    private var memoryGroup: some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            photoPrint
            reactionNote
            allergenInfo
        }
    }

    /// iPad：沖印品寬 290（照片 274×350）＋右側欄（反應／一句話／記錄者／過敏原，gap `$sp-group`）。
    private var memoryRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.block) {
            photoPrint.frame(width: 290)
            VStack(alignment: .leading, spacing: AppSpacing.group) {
                reactionNote
                allergenInfo
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Reaction Note（`L2Up0n`，gap `$sp-group`）：反應 chip（沒選整個隱藏）→ 一句話（沒寫隱藏）→「〇〇記錄」
    /// （查不到名字隱藏）。
    @ViewBuilder
    private var reactionNote: some View {
        let reaction = FoodRecordDetailCopy.reaction(shown.reaction)
        let note = shown.note.flatMap { $0.isEmpty ? nil : $0 }
        let author = store?.authorName.map(FoodRecordDetailCopy.recordedBy(displayName:))
        if reaction != nil || note != nil || author != nil {
            VStack(alignment: .leading, spacing: AppSpacing.group) {
                if let reaction {
                    FoodRecordReactionChip(reaction: reaction)
                }
                if let note {
                    Text(note)
                        .appFont(.body)
                        .foregroundStyle(Color.lsTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("foodRecordDetail.note")
                }
                if let author {
                    Text(author)
                        .appFont(.note)
                        .foregroundStyle(Color.lsTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("foodRecordDetail.recordedBy")
                }
            }
        }
    }

    /// Allergen Info（`BeDDV`）：info 圖示＋長版過敏原句（含免責），`$text-secondary`；沒有過敏原整列隱藏。
    @ViewBuilder
    private var allergenInfo: some View {
        if let sentence = FoodRecordDetailCopy.allergenSentence(item.allergens) {
            HStack(alignment: .top, spacing: AppSpacing.label) {
                Image(systemName: "info.circle").appIconFrame(.small)
                Text(sentence)
                    .appFont(.note)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Color.lsTextSecondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("foodRecordDetail.allergen")
        }
    }

    // MARK: - 動作鈕（權限三態）

    @ViewBuilder
    private var actionButtons: some View {
        if actions.contains(.edit) {
            FoodRecordEditButton { onRoute(.edit(shown)) }
        }
        if actions.contains(.delete) {
            FoodRecordDeleteButton { onRoute(.delete(shown)) }
        }
    }

    /// 重讀失敗：內容保留、上方加一條錯誤列（同 `FoodBookView.refreshFailureBanner` 的既有語彙）。
    /// `FoodRecordDetailStore.refresh()` 以世代號只讓最新一次寫回，連點不會亂序覆寫，這顆鈕不另外 disable（品牌硬約束不 `.disabled(`）。
    @ViewBuilder
    private var refreshFailureBanner: some View {
        if let error = store?.refreshError {
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                Text(error.userFacingMessage).appFont(.note)
                Spacer(minLength: 0)
                Button {
                    Task { await store?.refresh() }
                } label: {
                    Text("重新載入")
                        .appFont(.body, weight: .semibold)
                        .frame(minHeight: 48)
                }
            }
            .foregroundStyle(Color.lsTextPrimary)
        }
    }
}

import SwiftUI

/// 時間軸（app 首頁，LS-126 依 LS-119 核可稿）——`get_family_timeline` 卡片流三種 kind
/// （日記便箋卡／相簿卡／照片卡）、Day Divider 日分組、`ChildFilterBar` 篩選、下拉更新／
/// 捲底載入、Header 停靠「＋ 新增回憶」具名建立鈕。
///
/// merge LS-125（日記編輯器）：`onCreateMemory` 閉包預留（LS-125 併入前的暫時做法，票文
/// 環境段「不得依賴其未併入的型別」）在 LS-125 併入後改直接持有 `diaryAPIClient`／
/// `mediaUploadService`、`showsDiaryEditor` 狀態與導覽——同 LS-125 原本（舊路徑
/// `Features/TimelineView.swift`）的做法，Header 的「新增回憶」具名鈕取代原本導覽列的暫時
/// 「+」鈕（已整顆移除）。
struct TimelineView: View {
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore
    let timelineStore: TimelineStore
    let diaryAPIClient: DiaryAPIClient
    let mediaUploadService: MediaUploadService

    @State private var selectedChildID: UUID?
    @State private var showsDiaryEditor = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// merge-review R3（`add3f2c1` m1）：`feedScrollView` 內容區實際渲染寬度（已扣掉
    /// `screenPad`）——同 `DiaryDetailView.photoWallWidth` 既有量寬手法（`.background`
    /// 掛在 `.padding` 之前，量到的已經是扣掉 padding 後的內容寬）。`DiaryCardView` 曾經
    /// 自己用 `GeometryReader` 猜這個值，實測在 iPad `LazyVGrid` 兩欄時會被卡片內部
    /// `previewPhotosRow`（見該檔文件註解）的固定寬子節點污染，量到螢幕寬估計值而非真正
    /// 可用寬——改成在這裡（一個不含任何會自我膨脹的固定寬子節點的量測點）量一次，往下
    /// 傳給每張卡片，不再讓卡片自己量。初始值用螢幕寬估計，避免第一幀量到 0。
    @State private var feedContentWidth: CGFloat = UIScreen.main.bounds.width - 2 * AppSpacing.screenPad

    /// 家庭與寶貝篩選任一改變都要重新整理時間軸——合成單一 Hashable key，避免家庭
    /// 未變、只是切換寶貝篩選時多打一次 `childrenStore.refresh`（那支另外用自己的
    /// `.task(id:)` 只綁 familyID，見下）。
    private struct TimelineRefreshKey: Hashable {
        let familyID: UUID?
        let childID: UUID?
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                feedLayout(columns: 2)
            } else {
                feedLayout(columns: 1)
            }
        }
        .appBackground()
        // QA 視覺對稿 FAIL（LS-126 comment `461bdc15`）：`SectionContentView.content` 對
        // 每個 tab 套 `.navigationTitle(section.title)`，這裡沒有另外覆寫時系統會在最上方
        // 疊一個 large title「時間軸」，跟 `headerRow` 自己畫的「時間軸」＋pill 疊出兩個
        // 標題（4/4 變體：預設／深色／AX3／iPad 皆重現）。只在這個畫面覆寫隱藏系統 nav
        // bar，不動 `RootView`／`SectionContentView` 共用的 `.navigationTitle`（其他三個
        // tab 不受影響）；系統標題被隱藏後唯一的可見標題來源是 `headerRow` 的自訂 Text，
        // 兩處都補 `.accessibilityAddTraits(.isHeader)` 保留 heading 語意（不然 VoiceOver
        // 會少一個原本系統 large title 免費附帶的 heading landmark）。
        .toolbar(.hidden, for: .navigationBar)
        .task(id: familyStore.myFamily?.id) {
            guard let familyID = familyStore.myFamily?.id else { return }
            await childrenStore.refresh(familyID: familyID)
        }
        .task(id: TimelineRefreshKey(familyID: familyStore.myFamily?.id, childID: selectedChildID)) {
            guard let familyID = familyStore.myFamily?.id else { return }
            await timelineStore.refresh(familyID: familyID, childID: selectedChildID)
        }
        .navigationDestination(for: TimelineRoute.self) { route in
            switch route {
            case .diaryDetail(let diaryID):
                DiaryDetailView(diaryID: diaryID, timelineStore: timelineStore, childrenStore: childrenStore)
            }
        }
        .navigationDestination(isPresented: $showsDiaryEditor) {
            if let familyID = familyStore.myFamily?.id {
                DiaryEditorView(
                    familyID: familyID, diaryAPIClient: diaryAPIClient, mediaUploadService: mediaUploadService,
                    childrenStore: childrenStore
                )
            }
        }
    }

    // MARK: - 版面

    private func feedLayout(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            feedScrollView(columns: columns)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.item) {
            headerRow
            if !childrenStore.activeChildren.isEmpty {
                ChildFilterBar(childrenStore: childrenStore, selectedChildID: $selectedChildID)
            }
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, AppSpacing.label)
    }

    /// Pen 對稿修正：LS-119 稿（`design/littlesprout.pen` frame `yXSht`／`Header Row` `FCiMS`）
    /// 標題與建立鈕同列（`justifyContent: space_between`），不是分開兩層；稿面 Body 頂距也是
    /// `$sp-label`（8pt）而非原本誤用的 `$sp-item`（16pt）。
    ///
    /// delta 復審 m1：AX3 下「時間軸」標題（`.display` 字級隨 Dynamic Type 放大到 40pt）＋
    /// pill 同列會溢出（reviewer 實測約需 396pt、可用寬只有 393-2×24=345pt）。稿面 AX3 變體
    /// （`lKoZG`／`HLXo3`）的 Header Row 節點本身帶了明確 `gap:8`——這個 gap 值只在「標題與
    /// pill 分兩列、上下堆疊」時才有意義（同列 space-between 排法不需要、也不會標一個獨立
    /// gap 值），但對稿當下沒有機會再往下一層讀 Header Row 在 AX3 的實際子節點排法確認
    /// （Pen 現在被 LS-125 佔用，不能切檔補讀）——用讀到的這個間接線索定調：AX3 下改堆疊兩列
    /// （標題在上、pill 靠左在下），列距用稿面同一個 `gap:8` 值（`AppSpacing.label`）。
    /// `ViewThatFits` 依實際量到的寬度自動切換，不綁 `dynamicTypeSize` 門檻值（門檻值本身
    /// 也沒有稿面依據）——中英文字數不同時的溢出點本來就該用實測寬度判斷，不是猜一個字級
    /// 級距分界。若稿面實際排法與此不同，MUST 待 Pen 釋放後另補一輪確認（見 PR body）。
    private var headerRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) {
                Text("時間軸")
                    .appFont(.display, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                createMemoryButton
            }
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                Text("時間軸")
                    .appFont(.display, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                createMemoryButton
            }
        }
    }

    /// Header 停靠的具名建立鈕（Tab-root 慣例）——刻意**不**套 `motifs.md` 的釘底動作帶：
    /// 那個慣例服務「單一 CTA 貫穿全狀態、內容隨狀態變動」的表單類畫面，時間軸是內容持續
    /// 累積的 feed，CTA 屬於畫面「入口」而不是「收尾」，位置在上不在下。
    ///
    /// Pen 對稿修正：稿面 `cmp/Create Entry Button`（`zy3Ps`）是緊湊 pill（`cornerRadius:999`／
    /// `gap:6`／`padding:[9.5,16]`／icon 18×18 純加號，無外框圓），不是原本的全寬色塊——
    /// `padding-vertical` 對到既有 token `controlPaddingTap`（同一組值，`JoinWaitingView` 已有
    /// 相同 padding＋icon＋semibold 文字的先例）；icon 換成裸 `"plus"` `.small`（18pt）對應
    /// lucide 的純加號，不用會多畫一個圓的 `plus.circle.fill`。
    private var createMemoryButton: some View {
        Button { showsDiaryEditor = true } label: {
            HStack(spacing: AppSpacing.tight) {
                // delta 復審 m2：這顆現在被 `TapTargetGateScreenName.timelineDefaultState`
                // 正式量測，sentinel／違規訊息都靠 accessibility label 精準對到「新增回憶」
                // 這個字串——icon 若不隱藏，SF Symbol 預設的「Plus」會併進同一個 Button
                // 的合併 label，字串比對就對不上，隱藏成純裝飾（同 `PhotoCardView` 已有
                // 的 `accessibilityHidden` 先例：圖示旁邊已有文字時圖示本身不需要再唸一次）。
                Image(systemName: "plus").appIconFrame(.small).accessibilityHidden(true)
                Text("新增回憶").appFont(.body, weight: .semibold)
            }
            .padding(.vertical, AppSpacing.controlPaddingTap)
            .padding(.horizontal, AppSpacing.item)
            .background(Color.lsAccent, in: Capsule())
            // 稿面的 pill 純用內容高度（icon 18pt／17pt 字＋9.5pt 上下 padding）估算落在
            // 44pt 邊界附近——用不可見的 `minHeight` 撐大點擊區，不改變上面已經畫好的視覺
            // pill 尺寸（`.background` 掛在 `.frame` 之前，胖的是外層透明點擊區，不是看得到
            // 的色塊），同 `SettingsView` 登出鈕／`loadMoreTrigger` 重新載入鈕的既有手法。
            // delta 復審 m2：這顆本身已被 `TapTargetGateScreenName.timelineDefaultState`
            // 正式量測（見 `TapTargetGateHarness.swift`），是 `TimelineView` 目前唯一走出
            // `tap-target-exemptions.txt` 豁免路徑、有自動化覆蓋的元件；同畫面其餘元件（日
            // 分組卡片、捲底載入、失敗態重新載入鈕）仍需要 seed 資料與捲動狀態，豁免理由
            // 不變。
            .frame(minHeight: AppSpacing.section)
            .contentShape(Rectangle())
        }
        .foregroundStyle(Color.lsOnAccent)
    }

    private func feedScrollView(columns: Int) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.section) {
                if renderableEntries.isEmpty {
                    emptyOrLoadingState
                } else {
                    ForEach(dayGroups) { group in
                        daySection(group, columns: columns)
                    }
                    loadMoreTrigger
                }
            }
            // merge-review R3（`add3f2c1` m1）：量 `feedContentWidth`，見該 `@State` 文件
            // 註解——`.background` 必須掛在 `.padding` 之前（同 `DiaryDetailView.
            // photoWallWidth` 既有寫法），量到的才是扣掉 `screenPad` 後的內容寬。
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { feedContentWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in feedContentWidth = newValue }
                }
            )
            // Pen 對稿修正：稿面 ChildFilter 與 Feed 之間有獨立的 `Spacer Section`（44pt，
            // `yXSht` 節點 `H2Ga9h`）——原本這段落差全靠 `header` 的 16pt 底部 padding，
            // 稿面要求的 44pt「每畫面至少一次」地標間距沒有出現在這裡（只出現在 Day Group
            // 之間）。改成在這裡補上，並讓 `header` 不再自帶底部 padding，避免疊加。
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.section)
            .padding(.bottom, AppSpacing.section)
        }
        .refreshable {
            guard let familyID = familyStore.myFamily?.id else { return }
            await timelineStore.refresh(familyID: familyID, childID: selectedChildID)
        }
    }

    /// 單張卡片實際可用的外部寬度——`columns == 1` 時就是整個 feed 內容寬；`columns > 1`
    /// （iPad `LazyVGrid`）時依 `GridItem(.flexible())` 的既有演算法（欄距 `AppSpacing.label`
    /// 均分扣除後平分欄數）反推，跟 `LazyVGrid` 自己算出的欄寬一致。
    private func cardOuterWidth(columns: Int) -> CGFloat {
        guard columns > 1 else { return feedContentWidth }
        let totalGap = AppSpacing.label * CGFloat(columns - 1)
        return max(0, (feedContentWidth - totalGap) / CGFloat(columns))
    }

    /// merge-review R1 m3：`content == nil`（指到的 diary／album／media 因硬刪或 RLS 讀不到、
    /// 批次組裝那支剛好失敗）的項目 `cardView` 畫的是 `EmptyView()`——濾掉這種項目再分組，
    /// 不然會出現「只有 Day Divider、底下沒有卡片」的一天，看起來像空狀態卻不是空狀態畫面。
    private var renderableEntries: [TimelineEntry] {
        timelineStore.entries.filter { $0.content != nil }
    }

    private var dayGroups: [TimelineDayGrouping.Group] {
        TimelineDayGrouping.group(renderableEntries)
    }

    /// Pen 對稿修正：iPhone 單欄版稿面 Day Group（`yXSht` 節點 `b6iPyc`）Day Divider 與卡片
    /// 區塊之間是 `$sp-label`（8pt），不是卡片彼此之間用的 `$sp-item`（16pt，見下方內層
    /// `VStack`，那層維持不變）。iPad 多欄版型本輪對稿範圍未涵蓋（見 PR body「未驗」），
    /// `columns > 1` 分支維持原值，不在本次一併調整。
    @ViewBuilder
    private func daySection(_ group: TimelineDayGrouping.Group, columns: Int) -> some View {
        VStack(alignment: .leading, spacing: columns > 1 ? AppSpacing.block : AppSpacing.label) {
            DayDividerView(date: group.day)
            if columns > 1 {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.label), count: columns),
                    spacing: AppSpacing.label
                ) {
                    ForEach(group.entries) { entry in cardView(for: entry, columns: columns) }
                }
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.item) {
                    ForEach(group.entries) { entry in cardView(for: entry, columns: columns) }
                }
            }
        }
    }

    @ViewBuilder
    private func cardView(for entry: TimelineEntry, columns: Int) -> some View {
        switch entry.content {
        case .diary(let content):
            NavigationLink(value: TimelineRoute.diaryDetail(entry.refId)) {
                DiaryCardView(
                    content: content, taggedChildren: taggedChildren(for: entry), timelineStore: timelineStore,
                    previewRowWidth: max(0, cardOuterWidth(columns: columns) - 2 * AppSpacing.insetCard)
                )
            }
            .buttonStyle(.plain)
        case .album(let content):
            AlbumCardView(content: content)
        case .media(let content):
            PhotoCardView(content: content, timelineStore: timelineStore)
        case nil:
            EmptyView()
        }
    }

    private func taggedChildren(for entry: TimelineEntry) -> [Child] {
        childrenStore.children.filter { entry.childIds.contains($0.id) }
    }

    /// 捲到最後幾筆時觸發載入下一頁——不是捲到絕對底部才觸發，避免使用者要等到看到
    /// 螢幕最底才補資料的空拍。merge-review R1 m2：失敗時不能只留一個轉不停也不會重試的
    /// `ProgressView`——`.task` 只在這個 view 第一次出現時跑一次，`loadMoreState` 變成
    /// `.failure` 後 `hasMorePages` 依然是 true，轉圈會停在畫面底部卡住。失敗時改顯示
    /// 錯誤訊息＋可點的「重新載入」，不再顯示轉圈（因此也沒有懸而不決的 `.task`）。
    @ViewBuilder
    private var loadMoreTrigger: some View {
        if timelineStore.hasMorePages {
            if case .failure(let error) = timelineStore.loadMoreState {
                VStack(spacing: AppSpacing.tight) {
                    Text(error.userFacingMessage)
                        .appFont(.note)
                        .foregroundStyle(Color.lsTextSecondary)
                    // merge-review R2-M2：純文字 Button 沒有 padding／contentShape 時命中區
                    // 只有文字外框（repo 內同構造 `OTPVerificationView` 重寄鈕實測過
                    // 163.0×22.0pt，遠低於 44pt），改用 label closure 加 padding 撐大點擊區
                    // （同 `80af9e2` 既有慣例）。merge-review R3 r3-m1：原本只用
                    // `AppSpacing.group`（12pt）垂直 padding，換算命中區 ≈44.3pt，離 44pt
                    // 下限只有 0.3pt 餘裕、又剛好在 tap-target gate 豁免路徑（見下方
                    // 「未完成」欄）沒有自動化覆蓋兜底——改用 `SettingsView` 登出鈕同一個
                    // token（`AppSpacing.item`，16pt，垂直＋水平都套），命中區拉高到
                    // ≈52.3pt，留足夠餘裕。
                    Button {
                        Task { await timelineStore.loadMore() }
                    } label: {
                        Text("重新載入")
                            .appFont(.body, weight: .semibold)
                            .padding(.vertical, AppSpacing.item)
                            .padding(.horizontal, AppSpacing.item)
                            .contentShape(Rectangle())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.item)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.item)
                    .task {
                        await timelineStore.loadMore()
                    }
            }
        }
    }

    /// merge-review R1 m1：`refreshState == .failure` 之前跟「還沒有回憶」共用同一個空狀態
    /// 文案——離線或 RPC 500 會被呈現成「你家還沒有內容」，且沒有重試入口。失敗時改顯示
    /// 錯誤訊息＋「重新載入」，跟 `DiaryDetailView` 的行內錯誤提示一致（同一套語彙：
    /// `$text-primary` ＋ circle-alert，不用 danger，見 brand skill 規則 8）。
    @ViewBuilder
    private var emptyOrLoadingState: some View {
        switch timelineStore.refreshState {
        case .submitting:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .failure(let error):
            VStack(spacing: AppSpacing.item) {
                HStack(spacing: AppSpacing.tight) {
                    Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                    Text(error.userFacingMessage).appFont(.note)
                }
                .foregroundStyle(Color.lsTextPrimary)
                // merge-review R2-M2：同 `loadMoreTrigger` 的「重新載入」——label closure
                // 加 padding＋`contentShape`，不是裸 `Button(_:action:)`。merge-review R3
                // r3-m1：padding token 同上方 `loadMoreTrigger` 的理由，改用
                // `AppSpacing.item`（同 `SettingsView` 登出鈕），命中區 ≈52.3pt。
                Button {
                    Task {
                        guard let familyID = familyStore.myFamily?.id else { return }
                        await timelineStore.refresh(familyID: familyID, childID: selectedChildID)
                    }
                } label: {
                    Text("重新載入")
                        .appFont(.body, weight: .semibold)
                        .padding(.vertical, AppSpacing.item)
                        .padding(.horizontal, AppSpacing.item)
                        .contentShape(Rectangle())
                }
            }
            .frame(maxWidth: .infinity)
        case .idle, .success:
            ContentUnavailableView(
                "還沒有回憶",
                systemImage: "photo.stack",
                description: Text("點上方的「新增回憶」寫下第一篇日記，或加入照片。")
            )
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TimelineView(
            familyStore: .preview(), childrenStore: .preview(), timelineStore: .preview(),
            diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService()
        )
    }
}
#endif

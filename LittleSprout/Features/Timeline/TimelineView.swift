import SwiftUI

/// 時間軸（app 首頁，LS-126 依 LS-119 核可稿）——`get_family_timeline` 卡片流三種 kind
/// （日記便箋卡／相簿卡／照片卡）、Day Divider 日分組、`ChildFilterBar` 篩選、下拉更新／
/// 捲底載入、Header 停靠「＋ 新增回憶」具名建立鈕。
///
/// `onCreateMemory`：LS-125（日記編輯器）的入口以閉包預留（票文環境段：「不得依賴其未併入的
/// 型別」）——LS-125 併入後由呼叫端（`SectionContentView`）換成真正導向編輯器的閉包，這裡
/// 完全不 import 任何 LS-125 的型別。
struct TimelineView: View {
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore
    let timelineStore: TimelineStore
    var onCreateMemory: () -> Void = {}

    @State private var selectedChildID: UUID?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
            Text("時間軸")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            if !childrenStore.activeChildren.isEmpty {
                ChildFilterBar(childrenStore: childrenStore, selectedChildID: $selectedChildID)
            }
            createMemoryButton
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, AppSpacing.item)
        .padding(.bottom, AppSpacing.item)
    }

    /// Header 停靠的具名建立鈕（Tab-root 慣例）——刻意**不**套 `motifs.md` 的釘底動作帶：
    /// 那個慣例服務「單一 CTA 貫穿全狀態、內容隨狀態變動」的表單類畫面，時間軸是內容持續
    /// 累積的 feed，CTA 屬於畫面「入口」而不是「收尾」，位置在上不在下。
    private var createMemoryButton: some View {
        Button(action: onCreateMemory) {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "plus.circle.fill").appIconFrame(.medium)
                Text("新增回憶").appFont(.body, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.controlPaddingCTA)
        }
        .foregroundStyle(Color.lsOnAccent)
        .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
    }

    private func feedScrollView(columns: Int) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.section) {
                if renderableEntries.isEmpty {
                    emptyOrLoadingState
                        .padding(.horizontal, AppSpacing.screenPad)
                        .padding(.top, AppSpacing.section)
                } else {
                    ForEach(dayGroups) { group in
                        daySection(group, columns: columns)
                    }
                    loadMoreTrigger
                }
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.bottom, AppSpacing.section)
        }
        .refreshable {
            guard let familyID = familyStore.myFamily?.id else { return }
            await timelineStore.refresh(familyID: familyID, childID: selectedChildID)
        }
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

    @ViewBuilder
    private func daySection(_ group: TimelineDayGrouping.Group, columns: Int) -> some View {
        VStack(alignment: .leading, spacing: columns > 1 ? AppSpacing.block : AppSpacing.item) {
            DayDividerView(date: group.day)
            if columns > 1 {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.label), count: columns),
                    spacing: AppSpacing.label
                ) {
                    ForEach(group.entries) { entry in cardView(for: entry) }
                }
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.item) {
                    ForEach(group.entries) { entry in cardView(for: entry) }
                }
            }
        }
    }

    @ViewBuilder
    private func cardView(for entry: TimelineEntry) -> some View {
        switch entry.content {
        case .diary(let content):
            NavigationLink(value: TimelineRoute.diaryDetail(entry.refId)) {
                DiaryCardView(content: content, taggedChildren: taggedChildren(for: entry))
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
                    Button("重新載入") {
                        Task { await timelineStore.loadMore() }
                    }
                    .appFont(.body, weight: .semibold)
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
                Button("重新載入") {
                    Task {
                        guard let familyID = familyStore.myFamily?.id else { return }
                        await timelineStore.refresh(familyID: familyID, childID: selectedChildID)
                    }
                }
                .appFont(.body, weight: .semibold)
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

#Preview {
    NavigationStack {
        TimelineView(familyStore: .preview(), childrenStore: .preview(), timelineStore: .preview())
    }
}

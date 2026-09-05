import SwiftUI

/// 相簿 tab 首頁（LS-165，依 LS-142 稿）——取代原本的 `ContentUnavailableView` 佔位：卡片列表
/// （封面沖印品＋張數＋署名列＋扇影厚度分級）、空狀態（Blank Print）、「新增相簿」入口。
///
/// 標題比照時間軸／寶貝管理（`design/littlesprout.pen` `puHZ5` Notes `Jembn`）：不是系統
/// `navigationTitle`，是 Header Row 內的自畫 Title；但仍不隱藏系統 nav bar（同
/// `ChildrenManagementView`——不像 `TimelineView`額外 `.toolbar(.hidden, for: .navigationBar)`
/// 那樣，那支只服務時間軸自己的雙標題衝突，見該檔文件註解），系統 nav bar 標題交給
/// `SectionContentView.content` 既有的 `.navigationTitle(section.title)` 提供
/// entry-conditions.md ⑬（`SectionTabBarTests.testAlbumsRootShowsAlbumsHeading` 依此斷言）。
///
/// Tab Bar 顯示／隱藏由 `RootView.SectionTabView` 統一處理（掛在每個分頁的根內容上），這裡
/// 不需要另外處理。
struct AlbumsView: View {
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore
    let albumsStore: AlbumsStore

    @State private var showsCreateAlbum = false
    @State private var contentWidth: CGFloat = UIScreen.main.bounds.width - 2 * AppSpacing.screenPad
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.top, AppSpacing.label)
            scrollArea(columns: horizontalSizeClass == .regular ? 2 : 1)
        }
        .appBackground()
        .task(id: familyStore.myFamily?.id) {
            guard let familyID = familyStore.myFamily?.id else { return }
            await albumsStore.refresh(familyID: familyID)
        }
        .navigationDestination(for: AlbumRoute.self) { route in
            switch route {
            case .detail(let albumID):
                AlbumDetailView(albumID: albumID, albumsStore: albumsStore)
            }
        }
        .sheet(isPresented: $showsCreateAlbum) {
            if let familyID = familyStore.myFamily?.id {
                CreateAlbumView(familyID: familyID, albumsStore: albumsStore, childrenStore: childrenStore)
            }
        }
    }

    // MARK: - Header

    /// 同 `TimelineView.headerRow`：`ViewThatFits` 依實際量到的寬度在「標題與＋新增相簿鈕
    /// 同列」與「標題在上、鈕在下」之間自動切換（AX3 核可頁截圖 `IjWOp.png` 即為堆疊態）。
    private var headerRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) {
                titleText
                Spacer()
                addAlbumButton
            }
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                titleText
                addAlbumButton
            }
        }
    }

    private var titleText: some View {
        Text("相簿")
            .appFont(.display, weight: .bold)
            .foregroundStyle(Color.lsTextPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private var addAlbumButton: some View {
        Button {
            showsCreateAlbum = true
        } label: {
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: "plus").appIconFrame(.small).accessibilityHidden(true)
                Text("新增相簿").appFont(.body, weight: .semibold)
            }
            .padding(.vertical, AppSpacing.controlPaddingTap)
            .padding(.horizontal, AppSpacing.item)
            .background(Color.lsAccent, in: Capsule())
            .frame(minHeight: AppSpacing.section)
            .contentShape(Rectangle())
        }
        .foregroundStyle(Color.lsOnAccent)
    }

    // MARK: - 內容區（可捲動）

    private func scrollArea(columns: Int) -> some View {
        ScrollableFillView {
            contentBody(columns: columns)
                .background(widthMeasurement)
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.top, AppSpacing.section)
                .padding(.bottom, AppSpacing.section)
        }
        .refreshable {
            guard let familyID = familyStore.myFamily?.id else { return }
            await albumsStore.refresh(familyID: familyID)
        }
    }

    @ViewBuilder
    private func contentBody(columns: Int) -> some View {
        if albumsStore.albums.isEmpty, albumsStore.refreshState != .submitting {
            emptyState
        } else if columns > 1 {
            VStack(alignment: .leading, spacing: AppSpacing.block) {
                grid(columns: columns)
                loadMoreTrigger
            }
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.block) {
                list
                loadMoreTrigger
            }
        }
    }

    /// 卡間可見淨空（LS-142 Handoff Notes `EBlnw`）＝6：扇影最高可見裝飾頂在卡片自身頂緣之上
    /// 18pt（`AlbumFanGhostLayer.ghost1`／`ghost3` 皆 y −18），LazyVStack 間距 24
    /// （`AppSpacing.block`）扣掉扇影上探的 18，剛好留下 6pt 可見淨空——不是隨意選
    /// `AppSpacing.block`，是這個公式反推出來剛好對上既有 token 的結果。
    private var list: some View {
        LazyVStack(alignment: .leading, spacing: AppSpacing.block) {
            ForEach(albumsStore.albums) { album in
                albumCard(album, cardWidth: contentWidth)
            }
        }
    }

    /// iPad 兩欄，欄距 24（票文 Scope 4／LS-142 Notes `zGp4y`）——卡片本身用
    /// `.frame(maxWidth: .infinity)`（見 `AlbumSummaryCardView` 文件註解），`GridItem
    /// .flexible()` 已經保證每欄實際寬度相同，`columnWidth` 只餵給扇影幾何換算用。
    private func grid(columns: Int) -> some View {
        let columnWidth = max(0, (contentWidth - AppSpacing.block * CGFloat(columns - 1)) / CGFloat(columns))
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.block), count: columns),
            spacing: AppSpacing.block
        ) {
            ForEach(albumsStore.albums) { album in
                albumCard(album, cardWidth: columnWidth)
            }
        }
    }

    private func albumCard(_ album: AlbumSummary, cardWidth: CGFloat) -> some View {
        NavigationLink(value: AlbumRoute.detail(album.id)) {
            AlbumSummaryCardView(album: album, taggedChildren: taggedChildren(for: album), cardWidth: cardWidth)
        }
        .buttonStyle(.plain)
    }

    private func taggedChildren(for album: AlbumSummary) -> [Child] {
        childrenStore.children.filter { album.childIds.contains($0.id) }
    }

    private var widthMeasurement: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { contentWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, newValue in contentWidth = newValue }
        }
    }

    // MARK: - 空狀態（Blank Print）

    /// 核可頁截圖 `LTDYH.png`（空狀態）：空白沖印品＋「還沒有相簿」＋引導文案，垂直置中在
    /// Header 下緣與 Tab Bar 頂之間——`ScrollableFillView`（`scrollArea` 已包一層）負責
    /// 一般字級撐滿、AX 字級改可捲動的兩態切換，這裡只需要 `frame(maxHeight: .infinity)`
    /// 讓內容在可用高度內置中。
    private var emptyState: some View {
        VStack(spacing: AppSpacing.item) {
            Spacer(minLength: 0)
            blankPrint
            VStack(spacing: AppSpacing.label) {
                Text("還沒有相簿")
                    .appFont(.lead, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                Text("點右上角的「＋新增相簿」建立第一本相簿，把珍貴的回憶收藏起來。")
                    .appFont(.body)
                    .foregroundStyle(Color.lsTextSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .accessibilityElement(children: .combine)
    }

    private var blankPrint: some View {
        VStack(spacing: 7) {
            Rectangle().fill(Color.lsSurface2).frame(height: 184)
        }
        .padding(.top, AppSpacing.printEdge)
        .padding(.horizontal, AppSpacing.printEdge)
        .padding(.bottom, AppSpacing.printEdgeBottom)
        .background(Color.lsPrintPaper)
        .overlay(PhotoCornerOverlay(size: 26))
        .frame(maxWidth: 260)
        .accessibilityHidden(true)
    }

    // MARK: - 載入下一頁

    /// 同 `TimelineView.loadMoreTrigger`（理由見該檔文件註解，這裡不重複）。
    @ViewBuilder
    private var loadMoreTrigger: some View {
        if albumsStore.hasMorePages {
            if case .failure(let error) = albumsStore.loadMoreState {
                VStack(spacing: AppSpacing.tight) {
                    Text(error.userFacingMessage)
                        .appFont(.note)
                        .foregroundStyle(Color.lsTextSecondary)
                    Button {
                        Task { await albumsStore.loadMore() }
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
                        await albumsStore.loadMore()
                    }
            }
        }
    }
}

#if DEBUG
#Preview("有相簿") {
    let store = AlbumsStore.preview()
    store.seedForPreview(albums: [
        AlbumSummary(id: UUID(), title: "上禮拜的動物園一日遊", photoCount: 12, cover: nil, childIds: [], createdAt: Date()),
        AlbumSummary(id: UUID(), title: "跨年連假出遊", photoCount: 62, cover: nil, childIds: [], createdAt: Date())
    ])
    return NavigationStack {
        AlbumsView(familyStore: .preview(), childrenStore: .preview(), albumsStore: store)
    }
}

#Preview("空狀態") {
    NavigationStack {
        AlbumsView(familyStore: .preview(), childrenStore: .preview(), albumsStore: .preview())
    }
}
#endif

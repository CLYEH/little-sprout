import PhotosUI
import SwiftUI

/// 相簿詳情（LS-166，依 LS-142 稿：`pVSXP`／`yfZyT`／`ZXdu2`／`w0NxC`／`OysBA`／`rFiLJ`／
/// `FPaFl`）——LS-165 只建立最小佔位，這裡換成正式內容：瀑布流照片牆、加入照片（PhotosPicker
/// → `MediaUploadService` → LS-167 `UploadQueueSheetView` 真實接線）、多寶貝標記唯讀顯示、
/// 編輯相簿名稱、刪除相簿。
///
/// **整支畫面完全自畫導覽**（`.navigationBarBackButtonHidden(true)`＋`.toolbar(.hidden, for:
/// .navigationBar)`，同 `DiaryEditorView` 既有先例）——Notes `kHDk4` `OHMPk`：「用 cmp/Nav
/// Back（label＝"相簿"）」是設計稿裡一個獨立元件而非系統預設返回鍵，MJ-10 把「更多」從
/// Header Row 移到與返回鍵同列的 Nav Row，兩者要並排在同一個自畫列裡，系統 nav bar 的
/// toolbar bar button item 熱區也有既有踩雷記錄（`DiaryDetailView+ContentActions.swift`
/// 文件註解：量到 57×36pt），改自畫兩者都放一般 body 內容，`tap-target-check.sh` 才量得準。
///
/// **「更多」選單僅 owner 可見**（Notes `OHMPk` 原文「僅 owner 可見」，`childrenStore.myRole
/// == .owner`）——票文 dispatch 原文另提到「owner／建立者限定」，但這是描述後端
/// `set_album_deleted`／`set_album_children`／`albums.title` 直接 `.update()` 三者的授權模型
/// （見 docs/API.md §2／§4：後兩者其實是**僅建立者本人**、比「owner 任何一本」更窄），不是
/// 要求 UI 額外開放給非 owner 的建立者。Notes 是唯一針對「這顆選單什麼時候看得到」給出明確
/// 文字的來源，這裡以其為準；owner 若剛好不是這本相簿的建立者，送出編輯／刪除時會收到
/// `42501`／`LS027`，或（`albums.title` 這一半，merge-review R2 M1 修正前是靜默 0 列、
/// 現在已由 `SupabaseAlbumsAPIClient.updateAlbumTitle` 明確轉成 `AppError`）明確的失敗——
/// 三者錯誤文案都會呈現（`AlbumDetailStore.submitEdit`／`AlbumDeleteConfirmationSheet` 皆走
/// 既有 `AppError.userFacingMessage` 映射），不會靜默失敗或 crash——這個「看得到但改不動」的
/// 可見性落差本身記入 handoff（m5，不修＋理由：Notes 是唯一明確來源），若要更精確的可見性
/// 規則（例如「owner 或建立者才看得到編輯，僅 owner 看得到刪除」）需要另開票調整設計稿。
struct AlbumDetailView: View {
    let albumID: UUID
    let albumsStore: AlbumsStore
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore
    let mediaUploadService: MediaUploadService

    // LS-166：`showsEditAlbum`／`showsDeleteConfirmation`／`showsPhotosPicker`／
    // `uploadQueueStore`／`showsUploadQueueSheet`／`dismiss`／`isOwner` 不標 `private`——
    // `AlbumDetailView+Actions.swift`（Nav Row／更多選單／加入照片，跨檔案 extension）需要
    // 讀寫，Swift 的 `private` 以檔案為界，同 `DiaryDetailView`／`DiaryDetailView
    // +ContentActions.swift` 既有拆檔慣例（該檔文件註解）。
    @State private var detailStore: AlbumDetailStore?
    @State var uploadQueueStore: UploadQueueStore?
    @State var showsUploadQueueSheet = false
    @State var showsPhotosPicker = false
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State var showsEditAlbum = false
    @State var showsDeleteConfirmation = false
    @State private var contentWidth: CGFloat = UIScreen.main.bounds.width - 2 * AppSpacing.screenPad
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// 只在還沒建立 `detailStore` 之前查一次當「種子」（初始 title／childIds）——之後畫面上
    /// 顯示的一律讀 `detailStore` 自己的狀態（`rename`／`setChildren` 之後才是最新值，`
    /// albumsStore.albums` 這份列表快取不會自動同步，見該檔文件註解）。
    private var albumSeed: AlbumSummary? {
        albumsStore.albums.first { $0.id == albumID }
    }

    var isOwner: Bool {
        childrenStore.myRole == .owner
    }

    var body: some View {
        Group {
            if let detailStore {
                Group {
                    if horizontalSizeClass == .regular {
                        iPadLayout(detailStore)
                    } else {
                        compactLayout(detailStore)
                    }
                }
                .sheet(isPresented: $showsEditAlbum) {
                    EditAlbumView(detailStore: detailStore, childrenStore: childrenStore)
                }
                .sheet(isPresented: $showsDeleteConfirmation) {
                    AlbumDeleteConfirmationSheet(
                        albumID: albumID, albumTitle: detailStore.title, apiClient: albumsStore.apiClient,
                        onDeleted: albumDeleted
                    )
                }
                .sheet(isPresented: $showsUploadQueueSheet) {
                    if let uploadQueueStore {
                        UploadQueueSheetView(store: uploadQueueStore)
                    }
                }
                .photosPicker(
                    isPresented: $showsPhotosPicker, selection: $pickerSelection,
                    matching: .any(of: [.images, .videos])
                )
                .onChange(of: pickerSelection) { _, newItems in
                    guard !newItems.isEmpty else { return }
                    let itemsToLoad = newItems
                    pickerSelection = []
                    Task { await loadPicked(itemsToLoad, detailStore: detailStore) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .appBackground()
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task(id: albumID) {
            guard detailStore == nil, let familyID = familyStore.myFamily?.id, let seed = albumSeed else { return }
            let store = AlbumDetailStore(
                albumID: albumID, familyID: familyID, title: seed.title, childIDs: seed.childIds,
                apiClient: albumsStore.apiClient
            )
            detailStore = store
            await store.refresh()
        }
    }

    // MARK: - Compact (iPhone)：釘底 Action Bar

    private func compactLayout(_ store: AlbumDetailStore) -> some View {
        VStack(spacing: 0) {
            navRow
                .padding(.trailing, AppSpacing.item)
            ScrollView {
                bodyContent(store, containerWidth: contentWidth)
                    .background(widthMeasurement)
                    .padding(.horizontal, AppSpacing.screenPad)
                    .padding(.top, AppSpacing.label)
                    .padding(.bottom, AppSpacing.block)
            }
            Rectangle().fill(Color.lsBorder).frame(height: 1)
            actionBar
        }
    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            addPhotosBarButton
                .padding(.vertical, AppSpacing.item)
                .padding(.horizontal, AppSpacing.screenPad)
        }
        .background(Color.lsSurface)
    }

    // MARK: - Regular (iPad)：Nav Sidebar／Divider 由上層 `SectionSplitView` 提供，這裡只畫
    // Content Pane 本身（Detail Header 自畫 Nav Row＋Title＋Meta Row＋行內加入照片鈕，見
    // Notes `rFiLJ`）。

    private func iPadLayout(_ store: AlbumDetailStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                VStack(alignment: .leading, spacing: AppSpacing.block) {
                    navRow
                    titleText(store)
                    metaRow(store)
                    addPhotosInlineButton
                }
                photoGridOrEmptyState(store, containerWidth: contentWidth)
            }
            .background(widthMeasurement)
            .padding(.horizontal, AppSpacing.screenPadLarge)
            .padding(.top, AppSpacing.screenPadLarge)
        }
    }

    // MARK: - 共用內容（Header／Meta／Photo Grid）

    private func bodyContent(_ store: AlbumDetailStore, containerWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            titleText(store)
            metaRow(store)
                .padding(.top, AppSpacing.label)
            photoGridOrEmptyState(store, containerWidth: containerWidth)
                .padding(.top, AppSpacing.section)
        }
    }

    private func titleText(_ store: AlbumDetailStore) -> some View {
        Text(store.title)
            .appFont(.display, weight: .bold)
            .foregroundStyle(Color.lsTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    /// `ViewThatFits`：寬容器（iPad）張數與 Pills 同列，窄容器（iPhone）張數獨立一行、
    /// Pills 另起一行——同 `AlbumsView.headerRow` 既有的寬度自適應手法（該檔文件註解）。
    private func metaRow(_ store: AlbumDetailStore) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppSpacing.label) {
                countText(store)
                pillsRow(store)
            }
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                countText(store)
                pillsRow(store)
            }
        }
    }

    private func countText(_ store: AlbumDetailStore) -> some View {
        Text("\(store.photoCount) 張相片")
            .appNumericFont(.body, weight: .semibold)
            .foregroundStyle(Color.lsTextSecondary)
    }

    /// `cmp/Pill` 唯讀展示（Notes `BF6Cf`：「這些 Pill 一律唯讀展示...不受 44pt 點擊目標規則
    /// 約束」）——沿用 `ChildrenStore.children` 原本順序（依 birthday 排序），同
    /// `AlbumsView.taggedChildren(for:)` 既有分工。
    @ViewBuilder
    private func pillsRow(_ store: AlbumDetailStore) -> some View {
        let tagged = childrenStore.children.filter { store.childIDs.contains($0.id) }
        if !tagged.isEmpty {
            HStack(spacing: AppSpacing.label) {
                ForEach(tagged) { child in
                    Pill(icon: "figure.child", text: child.name)
                }
            }
        }
    }

    @ViewBuilder
    private func photoGridOrEmptyState(_ store: AlbumDetailStore, containerWidth: CGFloat) -> some View {
        switch store.loadState {
        case .submitting where store.photos.isEmpty:
            ProgressView().frame(maxWidth: .infinity).padding(.top, AppSpacing.section)
        case .failure(let error) where store.photos.isEmpty:
            loadFailureState(error, store: store)
        default:
            if store.photos.isEmpty {
                emptyState(width: containerWidth)
            } else {
                AlbumPhotoGridView(photos: store.photos, containerWidth: containerWidth)
            }
        }
    }

    private func loadFailureState(_ error: AppError, store: AlbumDetailStore) -> some View {
        VStack(spacing: AppSpacing.item) {
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                Text(error.userFacingMessage).appFont(.note)
            }
            .foregroundStyle(Color.lsTextPrimary)
            Button {
                Task { await store.refresh() }
            } label: {
                Text("重新載入")
                    .appFont(.body, weight: .semibold)
                    .padding(.vertical, AppSpacing.item)
                    .padding(.horizontal, AppSpacing.item)
                    .contentShape(Rectangle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSpacing.section)
    }

    // MARK: - 空狀態（Notes `ZXdu2`：Blank Print Cell，無 Caption 型印品）

    private func emptyState(width: CGFloat) -> some View {
        VStack(spacing: AppSpacing.block) {
            blankPrintCell(width: width)
            VStack(spacing: AppSpacing.label) {
                Text("還沒有照片").appFont(.lead, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                Text("點下方「加入照片」，開始把這本相簿的回憶放進來。")
                    .appFont(.body).foregroundStyle(Color.lsTextSecondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSpacing.item)
    }

    private func blankPrintCell(width: CGFloat) -> some View {
        Color.lsSurface2
            .frame(width: AlbumPhotoGridLayout.photoWidth(columnWidth: width), height: 184)
            .padding(.top, AlbumPhotoGridLayout.photoPaddingTop)
            .padding(.horizontal, AlbumPhotoGridLayout.photoPaddingHorizontal)
            .padding(.bottom, AlbumPhotoGridLayout.photoPaddingBottom)
            .background(Color.lsPrintPaper)
            .overlay(PhotoCornerOverlay(size: 26))
            .frame(maxWidth: width)
            .accessibilityHidden(true)
    }

    // Nav Row（自畫返回鍵＋更多選單）／加入照片／PhotosPicker 接線見
    // `AlbumDetailView+Actions.swift`（拆檔理由見該檔文件註解）。

    private var widthMeasurement: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { contentWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, newValue in contentWidth = newValue }
        }
    }
}

#if DEBUG
#Preview("有照片") {
    let store = AlbumsStore.preview()
    let albumID = UUID()
    store.seedForPreview(albums: [
        AlbumSummary(id: albumID, title: "2026 夏天的海邊", photoCount: 3, cover: nil, childIds: [], createdAt: Date())
    ])
    let children = ChildrenStore.preview()
    children.seedRoleForPreview(.owner)
    return NavigationStack {
        AlbumDetailView(
            albumID: albumID, albumsStore: store, familyStore: .preview(), childrenStore: children,
            mediaUploadService: PreviewMediaUploadService()
        )
    }
}

#Preview("空狀態") {
    let store = AlbumsStore.preview()
    let albumID = UUID()
    store.seedForPreview(albums: [
        AlbumSummary(id: albumID, title: "還沒命名的相簿", photoCount: 0, cover: nil, childIds: [], createdAt: Date())
    ])
    return NavigationStack {
        AlbumDetailView(
            albumID: albumID, albumsStore: store, familyStore: .preview(), childrenStore: .preview(),
            mediaUploadService: PreviewMediaUploadService()
        )
    }
}
#endif

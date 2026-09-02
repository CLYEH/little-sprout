import SwiftUI

/// 日記詳情（LS-126 票文 Scope 2）——日期章錨定＋年齡、全文、瀑布流照片牆、留言區預留結構
/// （LS-22 承接）。iPad 左右分欄：左欄 360pt 放照片牆、右欄放文字內容。
///
/// 只帶 `diaryID`：內文從 `timelineStore.entries` 依 id 查目前最新的一筆（同 `ChildrenRoute`
/// 的理由，見該檔文件註解），避免推入時捕捉到的舊資料在使用者停留期間過期。
struct DiaryDetailView: View {
    let diaryID: UUID
    let timelineStore: TimelineStore
    let childrenStore: ChildrenStore

    @State private var photos: [MediaContent] = []
    @State private var loadState: TimelineOperationState = .idle
    @State private var playingVideo: PlayingVideo?
    @State private var photoWallWidth: CGFloat = UIScreen.main.bounds.width - 2 * AppSpacing.screenPad
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var entry: TimelineEntry? {
        timelineStore.entries.first { $0.kind == .diary && $0.refId == diaryID }
    }

    private var diaryContent: DiaryContent? {
        guard case .diary(let content) = entry?.content else { return nil }
        return content
    }

    private var taggedChildren: [Child] {
        guard let entry else { return [] }
        return childrenStore.children.filter { entry.childIds.contains($0.id) }
    }

    var body: some View {
        Group {
            if let diaryContent {
                if horizontalSizeClass == .regular {
                    iPadLayout(diaryContent)
                } else {
                    compactLayout(diaryContent)
                }
            } else {
                missingOrLoadingState
            }
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task(id: diaryID) {
            loadState = .submitting
            do {
                photos = try await timelineStore.loadDiaryPhotos(diaryID: diaryID)
                loadState = .success
            } catch {
                loadState = .failure(AppError.map(error))
            }
        }
        .fullScreenCover(item: $playingVideo) { video in
            VideoPlayerScreen(url: video.url).ignoresSafeArea()
        }
    }

    // MARK: - Compact (iPhone)

    private func compactLayout(_ content: DiaryContent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.block) {
                header(content)
                bodyText(content)
                photoWallSection
                commentsPlaceholder
            }
            .padding(AppSpacing.screenPad)
            .background(
                GeometryReader { proxy in
                    Color.clear.onAppear { photoWallWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in photoWallWidth = newValue }
                }
            )
        }
    }

    // MARK: - Regular (iPad)：左欄 360pt 照片牆、右欄文字內容

    private func iPadLayout(_ content: DiaryContent) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: AppSpacing.block) {
                MasonryPhotoWallView(
                    photos: photos, containerWidth: 360, timelineStore: timelineStore,
                    onTapVideo: { playingVideo = PlayingVideo(url: $0.signedURL ?? URL(string: "about:blank")!) }
                )
                .frame(width: 360, alignment: .leading)

                VStack(alignment: .leading, spacing: AppSpacing.block) {
                    header(content)
                    bodyText(content)
                    commentsPlaceholder
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(AppSpacing.screenPadLarge)
        }
    }

    // MARK: - 共用區塊

    private func header(_ content: DiaryContent) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text(BirthdayFormat.displayString(from: content.entryDate))
                .appFont(.meta, weight: .semibold)
                .foregroundStyle(Color.lsTextSecondary)
            if !taggedChildren.isEmpty {
                Text(MultiChildCaptionFormatter.attributed(children: taggedChildren, asOf: content.entryDate))
            }
        }
    }

    private func bodyText(_ content: DiaryContent) -> some View {
        Text(content.body)
            .appFont(.body)
            .foregroundStyle(Color.lsTextPrimary)
    }

    @ViewBuilder
    private var photoWallSection: some View {
        if !photos.isEmpty {
            MasonryPhotoWallView(
                photos: photos, containerWidth: photoWallWidth, timelineStore: timelineStore,
                onTapVideo: { playingVideo = PlayingVideo(url: $0.signedURL ?? URL(string: "about:blank")!) }
            )
        } else if case .failure(let error) = loadState {
            // 日記內文本身載入成功、但附照那支查詢失敗時的行內提示——不吞掉錯誤
            // （fail loud），但也不因為附照失敗就整頁擋掉已經拿到的日記內文。
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                Text(error.userFacingMessage).appFont(.note)
            }
            .foregroundStyle(Color.lsTextPrimary)
        }
    }

    /// 留言區預留結構（LS-22 承接，票文「不做」明列）——只畫一個安靜的占位區塊，不含任何
    /// 留言／愛心互動。
    private var commentsPlaceholder: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Divider().overlay(Color.lsBorder)
            Text("留言")
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextSecondary)
            Text("留言功能即將推出。")
                .appFont(.meta)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    @ViewBuilder
    private var missingOrLoadingState: some View {
        if loadState.isSubmitting || entry == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "找不到這篇日記",
                systemImage: "questionmark.circle",
                description: Text("這篇日記可能已經被移除。")
            )
        }
    }
}

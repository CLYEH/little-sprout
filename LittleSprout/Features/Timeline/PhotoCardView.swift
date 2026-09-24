import SwiftUI

/// 時間軸照片卡（`cmp/Card Photo`，LS-126 票文 Scope 1）——沖印品母題單張照片／影片縮圖＋
/// 底部互動列（`InteractionRow`，LS-216）。影片顯示「影片 M:SS」徽章，**不自動播放、不內嵌
/// 播放器**（票文明文要求）——這裡只畫靜態縮圖＋徽章，完全沒有 `AVPlayer` 相關的 View。
///
/// 純顯示元件，不含導覽（票文 Scope 1 只描述時間軸主畫面的卡片外觀，沒有要求主時間軸的
/// 照片卡本身要能點開全螢幕——那個行為只在日記詳情的瀑布流照片牆才有，見
/// `MasonryPhotoWallView`／`VideoPlayerScreen`）。
struct PhotoCardView: View {
    let content: MediaContent
    /// LS-365：這則 media 標記的寶貝（`feed_items.child_ids`，由 `media_children` 聚合，LS-317），
    /// 依 `ChildrenStore.children` 原本順序——同 `DiaryCardView.taggedChildren` 的既有分工，
    /// 由呼叫端（`TimelineView.taggedChildren(for:)`）解析好傳入。
    let taggedChildren: [Child]
    /// LS-365：署名年齡的基準日＝`feed_items.occurred_at`（media 為 `coalesce(taken_at,
    /// created_at)`，LS-367 Notes `L0xP2`／畫面級屬性 `Lj8OY`）——照片拍下當時幾歲，不是現在。
    let occurredAt: Date
    let timelineStore: TimelineStore
    /// LS-345 R2：只為了轉手給 `InteractionRow`／`LikersListSheet`——見該型別文件註解。
    let familyStore: FamilyStore
    /// LS-218：`TimelineView.openComments(kind:refId:)` 開留言 sheet，見
    /// `InteractionRow.onOpenComments` 文件註解。
    var onOpenComments: () -> Void = {}

    /// `cmp/Card Photo`（`umJHD`）Photo Wrap `bjq5n` 高 184——LS-365 壓印行（Imprint Row
    /// `KRUtz`）回到卡上之後照稿；原本 220 是沒有壓印行時把那一行的高度併進照片（LS-126）。
    private static let photoHeight: CGFloat = 184

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            ZStack(alignment: .topLeading) {
                PrintPhotoCard(
                    photoHeight: Self.photoHeight,
                    mountPoolOpacity: .card,
                    showsImprint: false,
                    remoteURL: content.signedURL,
                    accessibilityLabel: accessibilityLabel,
                    imprintCaption: AnyView(PhotoCardSignature(children: taggedChildren, asOf: occurredAt))
                )
                if content.type == .video {
                    // 徽章貼著照片左下內緣、再空一個 `sp-label`（8）。LS-365：照片下方多了
                    // 高度隨字級／寶貝數變動的壓印行，不能再從卡片底部往上量——改用一個跟照片
                    // 等高、從 `printEdge` 開始的框把徽章釘在照片本身的左下角。
                    videoBadge
                        .padding(.leading, AppSpacing.printEdge + AppSpacing.label)
                        .padding(.bottom, AppSpacing.label)
                        .frame(height: Self.photoHeight, alignment: .bottomLeading)
                        .padding(.top, AppSpacing.printEdge)
                }
            }
            // LS-216：`content.id`＝這則 media 的 id，剛好就是 `TimelineEntry.refId`
            // （`kind == .media` 的 feed pointer 本來就以 media 自己的 id 當 ref_id）——
            // 不需要像 `DiaryCardView`／`AlbumCardView` 另外收一個 `refId` 參數。
            InteractionRow(
                kind: .media, refId: content.id, timelineStore: timelineStore, familyStore: familyStore,
                onOpenComments: onOpenComments
            )
        }
        .task(id: content.id) {
            // R2-M1（merge-review `b7ecfbf4`）：`isThumbnail` 時 `signedURL` 是縮圖 JPEG，
            // 不是可解出時長的影片檔——讀取必定失敗，從源頭跳過，不要浪費一次網路請求
            // （`TimelineStore.loadVideoDuration` 的 `failedDurations` 是給其他失敗情境的
            // 硬化，兩者互補，這裡不能只靠那一層擋，縮圖列連第一次嘗試都不該發生）。
            guard content.needsVideoDurationLookup, let url = content.signedURL else { return }
            await timelineStore.loadVideoDuration(mediaID: content.id, url: url)
        }
    }

    private var accessibilityLabel: String {
        content.type == .video ? VideoDurationFormat.badgeText(duration: duration) : "照片"
    }

    private var duration: TimeInterval? {
        timelineStore.displayDuration(for: content)
    }

    private var videoBadge: some View {
        // fix/LS-130-video-badge-fallback：樣式抽到 `VideoDurationBadge`（`DiaryCardView`
        // 附照預覽縮圖現在也用同一套），這裡的視覺輸出不變。
        VideoDurationBadge(duration: duration)
            .accessibilityHidden(true) // 已併入 PrintPhotoCard 的 accessibilityLabel。
    }
}

/// LS-365：照片卡壓印行的寶貝署名（LS-367 Notes `L0xP2` 實作契約；定案 1 `AGF13`／2 `LMMks`／
/// 3 `AoZvb`）。字串一律走 `AlbumSignatureFormatter`（「暱稱 ·(NBSP)年齡」，年齡內 NBSP／
/// WORD JOINER）——**不用** `MultiChildCaptionFormatter`（日記卡那套：多寶貝不帶「·」、年齡
/// 13pt、顏色隨深色反轉）。
///
/// 排列：`ViewThatFits(in: .horizontal)` 兩個候選，所有字級同一條規則——
///   1. 全部人用「、」串成單一 `Text`、`.lineLimit(1)`：一行放得下就用它。
///   2. 放不下 → `VStack` 每人一個 `Text`（不設 lineLimit，單人仍放不下時靠字元控制斷點：
///      姓名後折行、「·」領銜下一行），人與人之間 `personGap`（預設 8，隨字級放大，AX3 約 19）。
///   外層 `.accessibilityElement(children: .combine)`：不論落在哪個候選，VoiceOver 都把署名
///   念成一句。
///
/// 未標記：單一半形空白、保留一行高（卡高不變、角托不動），`.accessibilityHidden(true)`
/// 不念「未標記」（定案 2 `LMMks`）。
///
/// 樣式：`$print-ink-secondary`／`$fs-body`／regular——紙與墨不隨深色反轉（print-paper 家族）。
struct PhotoCardSignature: View {
    let children: [Child]
    let asOf: Date

    @ScaledMetric(relativeTo: .body) private var personGap: CGFloat = 8

    var body: some View {
        Group {
            if children.isEmpty {
                Text(AlbumSignatureFormatter.signatureText(children: [], asOf: asOf, isOneLinePerPerson: false))
                    .accessibilityHidden(true)
            } else {
                ViewThatFits(in: .horizontal) {
                    Text(AlbumSignatureFormatter.signatureText(
                        children: children, asOf: asOf, isOneLinePerPerson: false
                    ))
                    .lineLimit(1)
                    VStack(alignment: .leading, spacing: personGap) {
                        ForEach(children) { child in
                            Text(AlbumSignatureFormatter.segment(for: child, asOf: asOf))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(QAAccessibilityID.photoCardSignature)
            }
        }
        .appFont(.body)
        .foregroundStyle(Color.lsPrintInkSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: AppSpacing.item) {
        PhotoCardView(
            content: MediaContent(
                id: UUID(), type: .photo, width: 4, height: 3, thumbWidth: nil, thumbHeight: nil,
                storagePath: "preview/photo.jpg", isThumbnail: false, signedURL: nil, durationSeconds: nil
            ),
            taggedChildren: [
                Child(id: UUID(), name: "小安", birthday: Date(), avatarURL: nil, deletedAt: nil, createdAt: Date())
            ],
            occurredAt: Date(),
            timelineStore: .preview(),
            familyStore: .preview()
        )
        PhotoCardView(
            content: MediaContent(
                id: UUID(), type: .video, width: 16, height: 9, thumbWidth: nil, thumbHeight: nil,
                storagePath: "preview/video.mp4", isThumbnail: false, signedURL: nil, durationSeconds: 68
            ),
            taggedChildren: [],
            occurredAt: Date(),
            timelineStore: .preview(),
            familyStore: .preview()
        )
    }
    .padding()
}
#endif

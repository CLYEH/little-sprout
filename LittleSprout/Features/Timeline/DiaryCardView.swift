import SwiftUI

/// 時間軸日記卡（`cmp/Card Diary`，LS-126 票文 Scope 1）——多寶貝 caption＋日記全文（截斷）
/// ＋附照預覽（最多 3 張，第 3 張若還有更多張疊上「還有 N 張」暗蓋）。
///
/// 純顯示元件，不含導覽——外層（`TimelineView`）決定要不要包一層 `NavigationLink`。
struct DiaryCardView: View {
    let content: DiaryContent
    /// 這篇日記標記的寶貝，依 `ChildrenStore.children` 原本的順序（依 birthday 排序）——
    /// 不用 `childIds` 陣列本身的順序（那是 RPC 回傳的、無排序意義的陣列）。
    let taggedChildren: [Child]
    /// fix/LS-130-video-badge-fallback：附照預覽縮圖裡的影片要顯示「影片」／「影片 M:SS」
    /// 徽章、且無縮圖的舊影片要能讀時長，需要 `TimelineStore`（同 `PhotoCardView` 已有的
    /// 依賴）。
    let timelineStore: TimelineStore

    /// merge-review `443ec21a` i2（既有 LS-126 幾何缺陷，本輪順手修——同一 surface，QA 會
    /// 撞到）：`previewPhotosRow` 真正可用的內容寬（已扣掉 `insetCard` 左右 padding），由
    /// **呼叫端（`TimelineView`）算好傳進來**，不是這裡自己用 `GeometryReader` 猜。
    ///
    /// merge-review R3（`add3f2c1` m1）：原本在這裡用 `GeometryReader` 自我量寬的三版寫法
    /// （掛在 `previewPhotosRow` 自己身上／掛在外層 `.frame(maxWidth: .infinity)` 之後／
    /// 探針當 `VStack` 直接子節點）**全部實測失敗**——用 debug 埋樁＋像素量測逐一驗證，三版
    /// 量到的都是螢幕寬估計值（iPad 上約 944pt，即使外層已經用 `.frame(width:)` 固定成
    /// 460pt 也一樣），不是外層真正提供的寬度。根因：`previewPhotosRow` 內每格已經有
    /// `previewTileSize` 算出的固定 `.frame(width:)`，一旦 `previewTileSize` 用了錯誤的
    /// （過大的）初始估計值，`previewPhotosRow` 的**理想寬度**（HStack 3 格固定寬相加）
    /// 會遠超外層真正可用的空間——`.frame(maxWidth: .infinity)` 沒有實際上限（`.infinity`），
    /// 子節點理想寬度一旦超過上層提案就會把整條鏈往上撐大，任何掛在同一棵子樹裡的
    /// `GeometryReader`（不管是 `.background()`／`.overlay()`，或是 `VStack` 的另一個直接
    /// 子節點）量到的都是這個被撐大後的值，不是外層真正的提案——這不是「自我參照」那麼窄
    /// 的問題，是「同一個 `VStack` 裡有一個會失控膨脹的手足節點，量測會被它一起帶歪」。
    ///
    /// 唯一乾淨的解法：換到**外部量測、往下傳參數**——`TimelineView.feedContentWidth`
    /// （量整個 feed 內容區，不受任何單一卡片內部狀態影響）算出每欄實際可用寬，直接當
    /// `previewRowWidth` 傳進來；這裡完全不含 `GeometryReader`、不含任何會自我膨脹的
    /// `@State`，`previewTileSize` 是這個外部參數的純函式，沒有循環依賴可言。已在 iPhone
    /// （單欄）與 iPad（`LazyVGrid` 兩欄，用 harness 暫時套 `.frame(width:)` 模擬窄欄格）
    /// 模擬器像素量測驗證：兩種情境量到的 tile 邊長都正確跟著外層容器縮放。
    let previewRowWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.group) {
            if !taggedChildren.isEmpty {
                Text(MultiChildCaptionFormatter.attributed(children: taggedChildren, asOf: content.entryDate))
                    .lineLimit(2)
            }
            Text(content.body)
                .appFont(.body)
                .foregroundStyle(Color.lsTextPrimary)
                .lineLimit(4)
            if !content.previewPhotos.isEmpty {
                previewPhotosRow
            }
        }
        .padding(AppSpacing.insetCard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .accessibilityElement(children: .combine)
    }

    private var remainingPhotoCount: Int {
        max(0, content.totalPhotoCount - content.previewPhotos.count)
    }

    private var previewPhotosRow: some View {
        HStack(spacing: AppSpacing.label) {
            ForEach(Array(content.previewPhotos.enumerated()), id: \.element.id) { index, photo in
                let isLast = index == content.previewPhotos.count - 1
                previewThumbnail(photo, showsRemainingBadge: isLast && remainingPhotoCount > 0)
                    .frame(width: previewTileSize, height: previewTileSize)
            }
        }
    }

    /// 每格正方形邊長——用呼叫端算好傳進來的 `previewRowWidth` 反推，不再靠
    /// `.aspectRatio(1, contentMode: .fit)` 在 `HStack` 無界高度提案下「猜」，也不在這裡
    /// 用 `GeometryReader` 自我量寬（見 `previewRowWidth` 文件註解）。
    private var previewTileSize: CGFloat {
        let count = content.previewPhotos.count
        guard count > 0 else { return 0 }
        let totalGap = AppSpacing.label * CGFloat(max(0, count - 1))
        return max(0, (previewRowWidth - totalGap) / CGFloat(count))
    }

    @ViewBuilder
    private func previewThumbnail(_ photo: MediaContent, showsRemainingBadge: Bool) -> some View {
        ZStack {
            // 「疊紙」暗示：後面再墊一張角度／位移都極小的紙，暗示底下還有東西
            // （LS-126：稿面 Stack Sheet 精確規格待 Pen 復連後核對，見 handoff）。
            if showsRemainingBadge {
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .fill(Color.lsSurface2)
                    .rotationEffect(.degrees(4))
                    .offset(x: 2, y: 2)
            }
            thumbnailImage(photo)
                .overlay {
                    if showsRemainingBadge {
                        // 「還有 N 張」已經是 75% 黑蓋滿整格，跟影片徽章同時出現會互相蓋住、
                        // 在這麼小的格子裡也讀不清楚——兩者互斥，「還有 N 張」優先（資訊量
                        // 較大：使用者更需要知道「這篇還有更多」，而不是「這張是不是影片」）。
                        ZStack {
                            Color.black.opacity(0.75)
                            Text("還有\(remainingPhotoCount)張")
                                .appFont(.note, weight: .bold)
                                .foregroundStyle(Color.lsOnPhoto)
                        }
                    } else if photo.type == .video {
                        // fix/LS-130-video-badge-fallback（QA R2 comment `a999c9af`）：修前
                        // 這裡完全沒有影片專屬呈現——無縮圖的舊影片 `signedURL` 落回原始
                        // `.mov`，`AsyncImage` 解不出圖片，退回空白 `Color.lsSurface2` 矩形，
                        // 使用者完全看不出這格是影片。現在比照 `PhotoCardView` 貼一枚
                        // `VideoDurationBadge`：初始「影片」，`loadVideoDuration`（下方
                        // `.task`）讀到時長後換成「影片 M:SS」；縮圖列（`isThumbnail`）不
                        // 觸發讀取，恆顯示「影片」。
                        VStack {
                            Spacer(minLength: 0)
                            HStack {
                                VideoDurationBadge(duration: timelineStore.videoDurations[photo.id])
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(AppSpacing.tight)
                    }
                }
                // merge-review `443ec21a` M1：`.clipShape` 移到 `.overlay` 之後——修前掛在
                // `thumbnailImage` 內部、在 overlay 疊加之前就裁了，徽章／暗蓋一旦比格子大
                // 就會畫出圓角格子外側（實測右緣畫到卡片邊界外）。搬到這裡確保無論徽章多寬
                // 都不會溢出格子可視範圍——`previewTileSize` 已經是主要防線，這裡是保底。
                .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
        .task(id: photo.id) {
            // 同 `PhotoCardView` 的理由：`needsVideoDurationLookup` 為 false（縮圖列）時
            // 這裡連第一次嘗試都不該發生——`signedURL` 對它們是縮圖 JPEG，讀時長必定失敗。
            guard photo.needsVideoDurationLookup, let url = photo.signedURL else { return }
            await timelineStore.loadVideoDuration(mediaID: photo.id, url: url)
        }
    }

    private func thumbnailImage(_ photo: MediaContent) -> some View {
        Group {
            if let url = photo.signedURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.lsSurface2
                    }
                }
            } else {
                Color.lsSurface2
            }
        }
    }
}

#Preview {
    DiaryCardView(
        content: DiaryContent(
            body: "今天第一次自己翻身，笑得好開心，全家都在旁邊歡呼。",
            entryDate: Date(),
            previewPhotos: [
                MediaContent(
                    id: UUID(), type: .photo, width: 4, height: 3, thumbWidth: nil, thumbHeight: nil,
                    storagePath: "preview/1.jpg", isThumbnail: false, signedURL: nil
                ),
                MediaContent(
                    id: UUID(), type: .photo, width: 3, height: 4, thumbWidth: nil, thumbHeight: nil,
                    storagePath: "preview/2.jpg", isThumbnail: false, signedURL: nil
                ),
                MediaContent(
                    id: UUID(), type: .video, width: 16, height: 9, thumbWidth: nil, thumbHeight: nil,
                    storagePath: "preview/3.mov", isThumbnail: false, signedURL: nil
                )
            ],
            totalPhotoCount: 6
        ),
        taggedChildren: [
            Child(id: UUID(), name: "陳小安", birthday: Date(), avatarURL: nil, deletedAt: nil, createdAt: Date())
        ],
        timelineStore: .preview(),
        previewRowWidth: 320 - 2 * AppSpacing.insetCard
    )
    .padding()
}

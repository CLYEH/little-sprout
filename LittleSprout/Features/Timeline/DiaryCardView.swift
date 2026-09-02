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
    /// 撞到）：`previewPhotosRow` 實際渲染出的寬度。`HStack` 內每格疊 `.frame(maxWidth:
    /// .infinity)` ＋ `.aspectRatio(1, contentMode: .fit)` 在無界高度提案下不會真的把格子
    /// 壓成正方形（`.aspectRatio` 拿不到明確的寬度提案可以「fit」），量測證據：日記卡貼到
    /// 螢幕右緣、格子 146.7×110pt 而非稿面規格的 ~99×99pt 正方。改成量實際寬度後
    /// 顯式算出每格的邊長（同 `DiaryDetailView.photoWallWidth` 的既有量寬手法），不再靠
    /// `.aspectRatio` 自己「猜」。初始值用螢幕寬扣掉時間軸版心（`screenPad`）與卡片自身
    /// padding（`insetCard`）估一個合理值，避免第一幀量到 0 而整排塌縮——`GeometryReader`
    /// 量到真實寬度後立刻覆蓋。
    @State private var previewPhotosRowWidth: CGFloat = UIScreen.main.bounds.width
        - 2 * AppSpacing.screenPad - 2 * AppSpacing.insetCard

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
        // merge-review `443ec21a` i2：量實際渲染寬度，見 `previewPhotosRowWidth` 文件註解
        // ——同 `DiaryDetailView.compactLayout` 量 `photoWallWidth` 的既有手法，`.background`
        // 掛在 `.padding` 之前（這裡沒有額外 padding，`HStack` 本身就是要量的寬度）。
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear { previewPhotosRowWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in previewPhotosRowWidth = newValue }
            }
        )
    }

    /// 每格正方形邊長——用量到的實際列寬反推，不再靠 `.aspectRatio(1, contentMode: .fit)`
    /// 在 `HStack` 無界高度提案下「猜」（見 `previewPhotosRowWidth` 文件註解）。
    private var previewTileSize: CGFloat {
        let count = content.previewPhotos.count
        guard count > 0 else { return 0 }
        let totalGap = AppSpacing.label * CGFloat(max(0, count - 1))
        return max(0, (previewPhotosRowWidth - totalGap) / CGFloat(count))
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
        timelineStore: .preview()
    )
    .padding()
}

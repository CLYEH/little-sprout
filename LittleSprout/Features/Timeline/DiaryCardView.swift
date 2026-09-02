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
            }
        }
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
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
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
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
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

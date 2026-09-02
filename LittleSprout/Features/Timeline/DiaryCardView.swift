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
                        ZStack {
                            Color.black.opacity(0.75)
                            Text("還有\(remainingPhotoCount)張")
                                .appFont(.note, weight: .bold)
                                .foregroundStyle(Color.lsOnPhoto)
                        }
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
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
                    storagePath: "preview/1.jpg", signedURL: nil
                ),
                MediaContent(
                    id: UUID(), type: .photo, width: 3, height: 4, thumbWidth: nil, thumbHeight: nil,
                    storagePath: "preview/2.jpg", signedURL: nil
                ),
                MediaContent(
                    id: UUID(), type: .photo, width: 1, height: 1, thumbWidth: nil, thumbHeight: nil,
                    storagePath: "preview/3.jpg", signedURL: nil
                )
            ],
            totalPhotoCount: 6
        ),
        taggedChildren: [
            Child(id: UUID(), name: "陳小安", birthday: Date(), avatarURL: nil, deletedAt: nil, createdAt: Date())
        ]
    )
    .padding()
}

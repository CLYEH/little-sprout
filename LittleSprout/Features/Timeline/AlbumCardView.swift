import SwiftUI

/// 時間軸相簿卡（`cmp/Card Album`，LS-126 票文 Scope 1）——沖印品母題封面＋標題＋底部互動列
/// （`InteractionRow`，LS-216）。
///
/// 純顯示元件，不含導覽：相簿畫面本身不在本票範圍（票文「不做」），這裡只顯示卡片本身，
/// 不掛 tap 動作。LS-216：`InteractionRow` 的三顆按鈕不落在 `.accessibilityElement
/// (children: .combine)` 範圍內，見該型別文件註解與 `DiaryCardView` 同款處理。
struct AlbumCardView: View {
    let content: AlbumContent
    let timelineStore: TimelineStore
    /// LS-216：這本相簿的 id——`AlbumContent` 本身不帶 id（純顯示模型），理由同
    /// `DiaryCardView.refId` 文件註解。
    let refId: UUID
    var onOpenComments: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                PrintPhotoCard(
                    photoHeight: 190,
                    showsImprint: false,
                    remoteURL: content.cover?.signedURL,
                    accessibilityLabel: content.title
                )
                Text(content.title)
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            InteractionRow(kind: .album, refId: refId, timelineStore: timelineStore, onOpenComments: onOpenComments)
        }
    }
}

#if DEBUG
// LS-216 R2（merge-review R1 B1）：`timelineStore: .preview()` 是 DEBUG-only 工廠方法
// （`PreviewTimelineAPIClient.swift` 整支圍 `#if DEBUG`）——本檔原本的 `#Preview` 沒有圍欄
// （改前只用 `AlbumContent(...)`，不需要），本票加 `timelineStore` 參數後若不補圍欄，
// Release 組態會因為 `.preview()` 不存在而編譯失敗。同 `DiaryCardView.swift` 既有寫法。
#Preview {
    AlbumCardView(content: AlbumContent(title: "2026 夏天的海邊", cover: nil), timelineStore: .preview(), refId: UUID())
        .padding()
}
#endif

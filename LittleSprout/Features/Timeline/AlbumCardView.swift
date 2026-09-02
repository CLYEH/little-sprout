import SwiftUI

/// 時間軸相簿卡（`cmp/Card Album`，LS-126 票文 Scope 1）——沖印品母題封面＋標題。
///
/// 純顯示元件，不含導覽：相簿畫面本身不在本票範圍（票文「不做」），這裡只顯示卡片本身，
/// 不掛 tap 動作。
struct AlbumCardView: View {
    let content: AlbumContent

    var body: some View {
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
    }
}

#Preview {
    AlbumCardView(content: AlbumContent(title: "2026 夏天的海邊", cover: nil))
        .padding()
}

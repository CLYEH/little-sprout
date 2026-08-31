import SwiftUI

/// `cmp/Pill`：小圖示 ＋ 短文字的膠囊標籤（LS-107，07 家族三處共用：範例照片說明、邀請碼到期、
/// 剩餘可用次數）。`$surface-2` 底、`$radius-full`（膠囊）、圖示與文字皆 `$text-secondary`。
struct Pill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: AppSpacing.tight) {
            Image(systemName: icon)
                .appIconFrame(.small)
                .foregroundStyle(Color.lsTextSecondary)
            Text(text)
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .padding(.vertical, AppSpacing.label)
        .padding(.horizontal, AppSpacing.group)
        .background(Color.lsSurface2, in: Capsule())
    }
}

#Preview {
    HStack(spacing: AppSpacing.label) {
        Pill(icon: "eye", text: "範例")
        Pill(icon: "calendar", text: "8/29 到期")
        Pill(icon: "person.2", text: "還可用 5 次")
    }
    .padding()
}

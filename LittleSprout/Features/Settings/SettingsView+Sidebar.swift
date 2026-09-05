import SwiftUI

/// `SettingsView` 的 iPad（regular）sidebar，從 `SettingsView.swift` 拆出獨立檔案——加完
/// merge-review R1 B1 的手繪兩欄版面後那支檔案同時超過 SwiftLint `file_length`／
/// `type_body_length` 上限，理由同 `SettingsView+Profile.swift` 從主檔拆分的既有先例。
/// `SettingsView.regularSelection` 因此不再標 `private`（跨檔案 extension 存取不到，見該屬性
/// 宣告處），但仍不對外公開任何 API 意圖。
extension SettingsView {
    var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("設定")
                    .appFont(.lead, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .padding(AppSpacing.item)
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        regularSelection = section
                    } label: {
                        sidebarRow(section)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color.lsSurface)
    }

    /// 稿面 `B2DckT` Nav Item：選中＝`$print-paper` 底、`$print-ink` icon／文字；未選中＝
    /// 透明底、`$text-secondary` icon、`$text-primary` 文字。純 `Button`（不是 `List` 列），
    /// 見 `SettingsView.regularBody` 文件註解 B1 段。
    func sidebarRow(_ section: SettingsSection) -> some View {
        let isSelected = section == regularSelection
        return HStack(spacing: AppSpacing.group) {
            Image(systemName: section.icon)
                .appIconFrame(.medium)
                .foregroundStyle(isSelected ? Color.lsPrintInk : Color.lsTextSecondary)
            Text(section.title)
                .appFont(.body)
                .foregroundStyle(isSelected ? Color.lsPrintInk : Color.lsTextPrimary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.group)
        .padding(.horizontal, AppSpacing.item)
        .frame(minHeight: 44)
        .background(isSelected ? Color.lsPrintPaper : Color.clear)
        .contentShape(Rectangle())
    }
}

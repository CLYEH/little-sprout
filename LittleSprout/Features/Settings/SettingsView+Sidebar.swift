import SwiftUI

/// `SettingsView` 的 iPad（regular）sidebar，從 `SettingsView.swift` 拆出獨立檔案——加完
/// merge-review R1 B1 的手繪兩欄版面後那支檔案同時超過 SwiftLint `file_length`／
/// `type_body_length` 上限，理由同 `SettingsView+Profile.swift` 從主檔拆分的既有先例。
/// `SettingsView.regularSelection` 因此不再標 `private`（跨檔案 extension 存取不到，見該屬性
/// 宣告處），但仍不對外公開任何 API 意圖。
extension SettingsView {
    /// merge-review R2 M2：這裡原本鋪了 `Color.lsSurface`——`surface`／`print-paper` 兩個
    /// colorset 的亮色值都是 `#FBEBEC`（現況、非本票引入的巧合），鋪同色底把選中列的
    /// `$print-paper` 背景整個吃掉，亮色模式下五列長得一模一樣、分不出目前在哪一區。稿面
    /// `B2DckT` 的 `Sidebar`（`VogAw`）本身就沒有 `fill`——直接坐在 `$bg` 漸層上，不鋪任何
    /// 底色，讓選中列自己的紙托浮起來才看得出來。
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
    }

    /// 稿面 `B2DckT` Nav Item（`KGKyg`＝選中／`oO6z7`＝未選中）：選中＝`$print-paper` 底＋
    /// `$paper-edge` 1pt 邊框＋外陰影（`$paper-shadow`，offset y+2、blur 8）＋`$print-ink`
    /// icon／粗體文字；未選中＝透明底、無邊框無陰影、`$text-secondary` icon、`$text-primary`
    /// 一般粗細文字。merge-review R2 M2：R1 只做了背景色與 icon／文字顏色兩條線索，稿面另外
    /// 兩條（邊框、陰影）被省略，疊上 `surface`／`print-paper` 亮色同值的巧合，選中態在亮色
    /// 模式下完全看不出來——這裡照稿面補齊邊框與陰影，深色模式本來就靠色差夠明顯，不受影響。
    /// `.accessibilityAddTraits(isSelected ? .isSelected : [])`：同 `SectionTabBar` 既有慣例，
    /// 讓「選中態可辨識」這件事同時有機械可測的訊號（`SettingsViewIPadTests
    /// .testSidebarSelectionIsAccessibleAndDistinguishable`），不只是肉眼看顏色。純 `Button`
    /// （不是 `List` 列），見 `SettingsView.regularBody` 文件註解 B1 段。
    func sidebarRow(_ section: SettingsSection) -> some View {
        let isSelected = section == regularSelection
        return HStack(spacing: AppSpacing.group) {
            Image(systemName: section.icon)
                .appIconFrame(.medium)
                .foregroundStyle(isSelected ? Color.lsPrintInk : Color.lsTextSecondary)
            Text(section.title)
                .appFont(.body, weight: isSelected ? .bold : .semibold)
                .foregroundStyle(isSelected ? Color.lsPrintInk : Color.lsTextPrimary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.group)
        .padding(.horizontal, AppSpacing.item)
        .frame(minHeight: 44)
        .background(isSelected ? Color.lsPrintPaper : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                .strokeBorder(isSelected ? Color.lsPaperEdge : Color.clear, lineWidth: 1)
        )
        .shadow(color: isSelected ? Color.lsPaperShadow : Color.clear, radius: 8, x: 0, y: 2)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

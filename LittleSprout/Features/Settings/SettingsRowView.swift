import SwiftUI

/// LS-188：01 設定頁通用列——icon＋label（＋可選副標）＋可選 chevron，`design/littlesprout.pen`
/// `cmp/Settings Row`（`bZhuV`）的 SwiftUI 對應（icon 22×22＝`AppIconToken.medium`、chevron
/// 18×18＝`AppIconToken.small`、水平 padding `$inset-card`＝20、垂直 padding `$ctl-pad-tap`＝9.5，
/// 與稿面逐值對齊）。純顯示元件（同 `AlbumSummaryCardView`／`DiaryCardView` 的既有慣例）：
/// 導覽由外層 `SettingsView` 的 `NavigationLink`／`Button` 負責，這裡不建立任何 tappable 容器
/// 本身的語意（`.contentShape` 只是把 hit-test 形狀鎖定成矩形，供外層包裝使用）。
///
/// **垂直置中**（使用者 2026-09-05 核可 LS-152 稿的唯一意見：「01 設定頁家庭區塊的列文字要在
/// 列高內垂直置中」，本票直接以此為實作要求，`.pen` 另由設計 chore 補正）：`HStack` 預設
/// `alignment: .center` 已經把 icon／文字群組（label＋副標整組）／chevron 三者對齊列高正中線
/// ——不需要額外處理，這正是稿面 `cmp/Settings Row` `alignItems: center` 在 SwiftUI 端的天然
/// 對應。含副標的列（例如「個人」列的姓名＋「編輯顯示名稱與頭像」）一樣適用：文字群組是
/// 單一 `VStack`，被 `HStack` 當一個整體置中，不是逐行各自置中。
struct SettingsRowView: View {
    let icon: String
    let label: String
    var value: String?
    var isDestructive: Bool = false
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: AppSpacing.group) {
            Image(systemName: icon)
                .appIconFrame(.medium)
                .foregroundStyle(isDestructive ? Color.lsDanger : Color.lsTextSecondary)
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                Text(label)
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(isDestructive ? Color.lsDanger : Color.lsTextPrimary)
                if let value {
                    Text(value)
                        .appFont(.note)
                        .foregroundStyle(Color.lsTextSecondary)
                }
            }
            Spacer(minLength: AppSpacing.group)
            // 稿面「刪除帳號」列：icon／label 是 `$danger`，chevron 仍是 `$text-secondary`
            // （`bZhuV` descendant `mW0Ox` 的覆寫值）——chevron 顏色刻意不跟 `isDestructive`
            // 連動。
            if showsChevron {
                Image(systemName: "chevron.right")
                    .appIconFrame(.small)
                    .foregroundStyle(Color.lsTextSecondary)
            }
        }
        .padding(.vertical, AppSpacing.controlPaddingTap)
        .padding(.horizontal, AppSpacing.insetCard)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// LS-188：稿面「Card」容器（`$surface` 底、`$radius-lg` 圓角、`$border` 1pt 邊框，內含多列
/// 以 `$border` 1pt 分隔線相隔）——五區卡片（家庭／內容與安全／法律／帳號）共用同一個殼，
/// 「個人」卡只有一列所以直接沿用同一個殼、不需要分隔線（`SettingsCard` 的 `rows` builder
/// 天然處理：只有一個子視圖時不會插入 divider）。
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.lsSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                .strokeBorder(Color.lsBorder, lineWidth: 1)
        )
    }
}

/// `SettingsCard` 列間分隔線——稿面 `Divider`（`$border`、1pt）。
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.lsBorder)
            .frame(height: 1)
    }
}

#if DEBUG
#Preview {
    ScrollView {
        VStack(spacing: AppSpacing.block) {
            SettingsCard {
                SettingsRowView(icon: "person.2.fill", label: "家庭成員")
                SettingsRowDivider()
                SettingsRowView(icon: "person.badge.plus", label: "邀請家人")
                SettingsRowDivider()
                SettingsRowView(icon: "door.left.hand.open", label: "退出家庭")
            }
            SettingsCard {
                SettingsRowView(icon: "rectangle.portrait.and.arrow.right", label: "登出", showsChevron: false)
                SettingsRowDivider()
                SettingsRowView(icon: "trash", label: "刪除帳號", isDestructive: true)
            }
        }
        .padding(AppSpacing.screenPad)
    }
}
#endif

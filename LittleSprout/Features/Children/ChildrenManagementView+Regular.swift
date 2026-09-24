import SwiftUI

/// LS-370：iPad 左欄寶貝列，從 `ChildrenManagementView.swift` 拆出——加完之後那支檔案超過 SwiftLint
/// `file_length`／`type_body_length` 上限，同 `ChildrenManagementView+Detail.swift` 的拆檔先例。
///
/// 拿掉內層 split 後，`List(selection:)` 的系統選取底色（藍）與 plain 列白底會延伸進外層浮動側欄
/// 底下的 safe area（模擬器截圖實測）——改用 `Button` 列（同 `SettingsView.regularBody` 先例），
/// 選中態照稿面 `JbTfv` Sidebar Row：選中 $surface＋$control-line 1.5pt 圓角框、未選透明
/// （`VUX7q`／`Z8uNx`）。
extension ChildrenManagementView {
    func sidebarRow(_ child: Child) -> some View {
        let isSelected = child.id == selectedChildID
        return Button {
            selectedChildID = child.id
        } label: {
            HStack(spacing: AppSpacing.group) {
                ChildAvatarView(name: child.name, avatarURL: childrenStore.avatarURL(for: child))
                VStack(alignment: .leading, spacing: AppSpacing.tight) {
                    Text(child.name).appFont(.body, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                    Text(BirthdayFormat.ageDescription(birthday: child.birthday))
                        .appFont(.note)
                        .foregroundStyle(Color.lsTextSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, AppSpacing.label)
            .padding(.horizontal, AppSpacing.group)
            .background(
                isSelected ? Color.lsSurface : Color.clear,
                in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(isSelected ? Color.lsControlLine : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

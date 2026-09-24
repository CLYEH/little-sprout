import SwiftUI

/// iPad（regular）版寶貝管理——LS-370 從 `ChildrenManagementView.swift` 拆出（加完之後那支檔案超過
/// SwiftLint `file_length`／`type_body_length` 上限，同 `ChildrenManagementView+Detail.swift` 的拆檔先例）。
///
/// 簡化版 iPad master-detail：與 09-iPad 稿面的結構一致（左欄清單／新增，右欄詳情）。LS-312 導覽入口
/// 接線起，右欄顯示寶貝詳情（`childDetail(for:)`，同 compact 版），「編輯」從詳情頁 Identity Header 進入。
/// 未逐像素比照稿面把 09b「取消」文字鈕挪動位置——LS-113 時間預算下的已知簡化。
///
/// **LS-370**：原本這裡再包一層 `NavigationSplitView`，疊在 `RootView.SectionSplitView` 的 detail 欄
/// （它自己的 `NavigationStack`）裡——iPad Pro 13 上「寶貝」出現三次：外層系統 large title、內層側欄
/// `.navigationTitle`、`headerSection` 自畫。稿面 `JbTfv`（09-iPad）是單一 split：左 Sidebar（320pt，
/// 自畫 Title「寶貝」＋清單＋新增鈕）｜Divider｜右 Detail Pane，沒有系統標題。改成外層 split 的 detail
/// 欄內用 `HStack` 畫這兩欄（同 `SettingsView.regularBody` 拿掉內層 split 的先例，LS-188 merge-review R1
/// B1），不再有第二層導覽容器；系統標題比照 `AlbumsView`（LS-355）／`TimelineView`（LS-369）：nav bar
/// 保留（外層「顯示側邊欄」鈕的容身處，不得無條件隱藏——LS-344 R1 M1），`.inline`＋零尺寸
/// `.principal` 關掉系統標題。回歸測試：`ChildrenManagementViewIPadTests`。
///
/// **窄欄退路**：外層側欄展開時 detail 欄可能很窄（iPad Air 11 直向實測約 490pt）——左欄固定 320pt 後右欄
/// 只剩 170pt，寶貝詳情的內容撐破容器、整排被擠到外層側欄底下與螢幕右緣外（模擬器截圖實測）。舊的內層
/// split 在這個寬度會自行收成單欄；這裡用量到的寬度做同一件事：放不下兩欄就只畫左欄清單，點寶貝改推詳情
/// 到外層 `NavigationStack`（返回鍵回清單）。已知行為：兩欄模式下右欄「編輯」與左欄「新增寶貝」同樣推到
/// 外層 `NavigationStack`、蓋掉整個 detail 欄（同 `SettingsView.regularBody` 已記載的限制）。
///
/// 左欄列不用 `List(selection:)`：拿掉內層 split 後，系統選取底色（藍）與 plain 列白底會延伸進外層浮動
/// 側欄底下的 safe area（模擬器截圖實測）——改用 `Button` 列（同 `SettingsView.regularBody` 先例），選中態
/// 照稿面 `JbTfv` Sidebar Row：選中 $surface＋$control-line 1.5pt 圓角框、未選透明（`VUX7q`／`Z8uNx`）。
extension ChildrenManagementView {
    /// 左欄固定寬（稿面 `umGAK` Sidebar w=320）。
    static let regularSidebarWidth: CGFloat = 320
    /// 右欄至少要有的寬度，否則退回單欄——iPad Pro 13 直向＋外層側欄展開時右欄約 381pt（實測可讀），
    /// iPad Air 11 同情境約 170pt（撐破），取 360 落在兩者之間。
    static let regularDetailMinWidth: CGFloat = 360

    var regularLayout: some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.regularSidebarWidth + 1 + Self.regularDetailMinWidth {
                HStack(spacing: 0) {
                    sidebarContent(pushesDetail: false)
                        .frame(width: Self.regularSidebarWidth)
                    Divider()
                    regularDetailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                sidebarContent(pushesDetail: true)
            }
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 0, height: 0).accessibilityHidden(true) }
        }
    }

    @ViewBuilder
    private var regularDetailPane: some View {
        if let selectedChildID, let child = childForID(selectedChildID) {
            childDetail(for: child)
        } else {
            ContentUnavailableView(
                "選擇一個寶貝",
                // LS-160：與 LS-150 已核可的寶貝 tab icon 語彙一致（AppSection.children.systemImage）。
                systemImage: "stroller.fill",
                description: Text("在左側選擇要編輯的寶貝檔案。")
            )
        }
    }

    private func sidebarContent(pushesDetail: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            headerSection
                .padding(.horizontal, AppSpacing.screenPadLarge)
                .padding(.top, AppSpacing.screenPadLarge)
            ScrollView {
                VStack(spacing: AppSpacing.tight) {
                    ForEach(childrenStore.activeChildren) { child in
                        sidebarRow(child, pushesDetail: pushesDetail)
                    }
                }
                .padding(.leading, AppSpacing.screenPadLarge)
                .padding(.trailing, AppSpacing.block)
            }
            if childrenStore.canManageChildren {
                NavigationLink {
                    CreateChildView(childrenStore: childrenStore)
                } label: {
                    HStack(spacing: AppSpacing.label) {
                        Image(systemName: "person.crop.circle.badge.plus").appIconFrame(.medium)
                        Text("新增寶貝").appFont(.body)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.controlPaddingCTA)
                }
                .foregroundStyle(Color.lsOnAccent)
                .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                .padding(.horizontal, AppSpacing.screenPadLarge)
                .padding(.bottom, AppSpacing.item)
            }
        }
    }

    @ViewBuilder
    private func sidebarRow(_ child: Child, pushesDetail: Bool) -> some View {
        if pushesDetail {
            NavigationLink {
                childDetail(for: child)
            } label: {
                sidebarRowLabel(child, isSelected: false, showsChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            let isSelected = child.id == selectedChildID
            Button {
                selectedChildID = child.id
            } label: {
                sidebarRowLabel(child, isSelected: isSelected, showsChevron: false)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private func sidebarRowLabel(_ child: Child, isSelected: Bool, showsChevron: Bool) -> some View {
        HStack(spacing: AppSpacing.group) {
            ChildAvatarView(name: child.name, avatarURL: childrenStore.avatarURL(for: child))
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                Text(child.name).appFont(.body, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                Text(BirthdayFormat.ageDescription(birthday: child.birthday))
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
            // AX3 實測：原本 `Spacer` 分寬時 320pt 欄寬下年齡文字折兩行後被截成「1 歲 5…」——文字欄
            // 直接吃滿剩餘寬度、垂直方向依內容長高。
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // 單欄退路是「推入詳情」語意，比照 compact 版列尾 chevron（`childRowContent`）。
            if showsChevron {
                Image(systemName: "chevron.right")
                    .appIconFrame(.medium)
                    .foregroundStyle(Color.lsTextSecondary)
            }
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
}

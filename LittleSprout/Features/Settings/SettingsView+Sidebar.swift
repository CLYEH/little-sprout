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
    ///
    /// merge-review R3 m1：R3 拿掉 `.background(Color.lsSurface)` 之後**沒有補上** `$bg`，
    /// 露出系統預設背景——實測亮色是純白 `#FFFFFF`、深色是純黑 `#000000`，跟稿面「坐在 `$bg`
    /// 上」與右側 detail 欄的 `Color.lsBackground` 都不一致，整個 app 的暖粉色調旁邊多了一條
    /// 突兀的白／黑長條。這裡補回 `Color.lsBackground`——不是 `Color.lsSurface`（那是 R2 M2
    /// 真正的病灶，會再度蓋掉選中列的紙托）。
    ///
    /// merge-review R3 M3：`.accessibilityAddTraits`／`.accessibilityValue` 套在這裡的
    /// `Button` 本身（不是 `sidebarRow` 回傳的內容視圖上）——實測 `Button` 對自訂 `label:`
    /// 內容合成 accessibility element 時，不會把子視圖上這兩個修飾詞往上帶，套在
    /// `sidebarRow` 內部完全測不到（見 `sidebarRow` 文件註解的實測發現段落）。
    var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("設定")
                    .appFont(.lead, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .padding(AppSpacing.item)
                ForEach(SettingsSection.allCases) { section in
                    let isSelected = section == regularSelection
                    Button {
                        regularSelection = section
                    } label: {
                        sidebarRow(section)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityValue(isSelected ? "已選取" : "")
                }
            }
        }
        .background(Color.lsBackground)
    }

    /// 稿面 `B2DckT` Nav Item（`KGKyg`＝選中／`oO6z7`＝未選中）：選中＝`$print-paper` 底＋
    /// `$paper-edge` 1pt 邊框＋外陰影（`$paper-shadow`，offset y+2、blur 8）＋`$print-ink`
    /// icon／粗體文字；未選中＝透明底、無邊框無陰影、`$text-secondary` icon、`$text-primary`
    /// 一般粗細文字。純 `Button`（不是 `List` 列），見 `SettingsView.regularBody` 文件註解
    /// B1 段。
    ///
    /// merge-review R3 M3（major）：「選中長什麼樣」原本直接寫死在這支函式的 view 修飾詞鏈
    /// 裡，reviewer 四組 mutation 證明沒有任何機械測試真的守住它——`SettingsViewIPadTests
    /// .testSidebarSelectionIsAccessibleAndDistinguishable` 斷言的 `XCUIElement.isSelected`
    /// 訊號來源跟 `.accessibilityAddTraits(isSelected ? .isSelected : [])` 這行完全無關
    /// （對所有列都套用該 trait、或把 M2 的視覺修法整個中性化，測試依然全綠；唯一「轉紅」的
    /// mutation 其實是刪掉這行造成的 app crash，不是斷言鑑別力）。R4 修法：把「選中長什麼樣」
    /// 抽成 `SettingsSidebarRowStyle`（見 `SettingsModels.swift`）這個純資料型別，`sidebarRow`
    /// 只負責套用算好的值——`SettingsSidebarRowStyleTests` 直接比較
    /// `.style(isSelected: true) != .style(isSelected: false)` 且逐欄位對照稿面 token，
    /// mutation b（中性化視覺修法）會讓這條單元測試直接紅，不再依賴 UITest 對 SwiftUI
    /// accessibility 語意的間接推論。
    ///
    /// **R4 實測發現的真正病灶**：`.accessibilityAddTraits`／`.accessibilityValue` 原本都是
    /// 套在這支函式回傳的 `HStack`（Button 的 `label:` 內容）上，而不是套在 `sidebar` 裡真正
    /// 的 `Button` 本身。實測（R4 第一次改法先把 `.accessibilityValue` 也放在這裡）證明：
    /// `Button` 對自訂 `label:` 內容預設會合成自己的單一 accessibility element，但這個合成
    /// **不會**把子視圖上的 `.accessibilityValue`／`.accessibilityAddTraits` 往上帶——UITest
    /// 讀到的 `XCUIElement.value` 是 `nil`、`.isSelected` 也不受影響。這正是 R3 M3 一開始就測不
    /// 出東西的根本原因（不只是「`.isSelected` 這個 API 不可靠」，而是「這兩個修飾詞下在錯的
    /// 節點上，Button 完全沒有往上帶」）。R4 修法：把 `.accessibilityAddTraits`／
    /// `.accessibilityValue` 移到 `sidebar` 裡包住 `sidebarRow(section)` 的 `Button` 本身
    /// （見 `sidebar` 文件註解），`sidebarRow` 不再套用這兩個修飾詞。
    ///
    /// `.accessibilityValue("已選取")`：選中態同時編碼成 XCUITest 讀得到的
    /// `XCUIElement.value`（`accessibilityValue` 是獨立於 trait 的另一個 accessibility 語意
    /// 通道）——`SettingsViewIPadTests` 改斷言「恰好一列的 value 是『已選取』且等於目前選取的
    /// 區塊」，這是四組 mutation 都能正確分辨的訊號，見該測試檔文件註解。
    ///
    /// `.accessibilityAddTraits(isSelected ? .isSelected : [])` 予以保留（R4 未拿掉）：
    /// reviewer 已證明它對 XCUITest 的 `.isSelected` 讀值無效，但語意上仍是 VoiceOver 使用者
    /// 「這顆目前被選取」的標準表達方式（同 `SectionTabBar` 既有慣例）——沒有 VoiceOver 實測
    /// 佐證它真的有加分，但也沒有理由拿掉一個標準、無害的 accessibility 語意標記，只是不能
    /// 再拿它當「機械測試守住了選中態」的證據（那個責任交給 `.accessibilityValue`＋
    /// `SettingsSidebarRowStyleTests` 兩層）。
    ///
    /// merge-review R3 informational 3：陰影 `radius` 原本直接套用稿面 `blur: 8` 的數字，跟
    /// repo 既有 `$paper-shadow` 用法（`SectionTabBar` 等處 radius 1.5／2／3／5，約為稿面
    /// blur 值的一半）不同調——這裡改成 4（8 的一半），與既有慣例對齊；視覺上兩者差異不明顯
    /// （這顆陰影本來就很淡），不需要重新截圖比對。
    func sidebarRow(_ section: SettingsSection) -> some View {
        let isSelected = section == regularSelection
        let style = SettingsSidebarRowStyle.style(isSelected: isSelected)
        return HStack(spacing: AppSpacing.group) {
            Image(systemName: section.icon)
                .appIconFrame(.medium)
                .foregroundStyle(isSelected ? Color.lsPrintInk : Color.lsTextSecondary)
            Text(section.title)
                .appFont(.body, weight: style.fontWeight)
                .foregroundStyle(isSelected ? Color.lsPrintInk : Color.lsTextPrimary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.group)
        .padding(.horizontal, AppSpacing.item)
        .frame(minHeight: 44)
        .background(style.background)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                .strokeBorder(style.borderColor, lineWidth: 1)
        )
        .shadow(color: style.shadowColor, radius: 4, x: 0, y: 2)
        .contentShape(Rectangle())
    }
}

import Foundation
import SwiftUI

/// LS-188：01 設定頁「內容與安全」區塊的列組成——依角色決定「檢舉紀錄」列在不在（稿面：
/// 檢舉收件匣僅 Owner 可見，票文範圍 1）。抽成純函式（不含任何 View／async 依賴）方便
/// XCTest 直接覆蓋這條判斷，不需要真的渲染 SwiftUI 視圖（同 `UploadFailureReason`／
/// `ChildFilterLayout` 這類「View 只認清單、判斷邏輯抽出去測」的既有慣例）。
///
/// `SettingsView.contentSafetySection` 依這份清單順序建列；`.blockList`／`.storage` 兩列
/// 兩種角色都會出現，`.reportInbox` 只在 `isOwner` 為 true 時插在中間。
enum SettingsContentSafetyRow: Equatable {
    case blockList
    case reportInbox
    case storage
}

enum SettingsContentSafetyComposition {
    static func rows(isOwner: Bool) -> [SettingsContentSafetyRow] {
        isOwner ? [.blockList, .reportInbox, .storage] : [.blockList, .storage]
    }
}

/// merge-review R3 M3：iPad sidebar「選中列長什麼樣」抽成純資料，同上面
/// `SettingsContentSafetyComposition` 的既有作法——`SettingsView+Sidebar.sidebarRow` 只負責
/// 套用這裡算出來的值，`SettingsSidebarRowStyleTests` 直接比較 selected／unselected 兩組
/// 是否不同、且逐欄位對照稿面 token，不必透過渲染＋UITest 間接推論（reviewer 實測：UITest
/// 對這類純視覺退化沒有鑑別力，見 `SettingsView+Sidebar.swift` `sidebarRow` 文件註解）。
struct SettingsSidebarRowStyle: Equatable {
    let background: Color
    let borderColor: Color
    let shadowColor: Color
    let fontWeight: Font.Weight

    /// 稿面 `B2DckT` 選中 Nav Item（`KGKyg`）／未選中（`oO6z7`）的逐值對照：選中＝
    /// `$print-paper` 底＋`$paper-edge` 邊框＋`$paper-shadow` 陰影＋粗體；未選中＝全透明、
    /// 一般粗細。
    static func style(isSelected: Bool) -> SettingsSidebarRowStyle {
        isSelected
            ? SettingsSidebarRowStyle(
                background: .lsPrintPaper, borderColor: .lsPaperEdge, shadowColor: .lsPaperShadow,
                fontWeight: .bold
              )
            : SettingsSidebarRowStyle(
                background: .clear, borderColor: .clear, shadowColor: .clear, fontWeight: .semibold
              )
    }
}

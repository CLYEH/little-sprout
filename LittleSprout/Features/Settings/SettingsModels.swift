import Foundation

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

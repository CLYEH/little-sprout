import Foundation

/// LS-190（依 LS-152 稿 `oFRMc`）：刪除日記確認頁的標題文案——把日記內文摘要嵌進「要刪除
/// 「⋯」這篇日記嗎？」這句話。抽成純函式，跟 View 分離，方便單元測試（不需要建構
/// `DeleteConfirmationSheet` 或任何 store）。
enum DiaryDeleteConfirmationCopy {
    /// 稿面範例「今天在溜滑梯上玩得好開心。」（12 字）完整顯示、未截斷——這裡取一個比範例
    /// 寬裕的上限，避免真實日記（可能是長篇段落）把標題撐成好幾行。
    static let maxExcerptLength = 20

    static func title(forBody body: String) -> String {
        "要刪除「\(excerpt(from: body))」這篇日記嗎？"
    }

    /// 換行摺成空白（標題是單行語意，不需要保留段落斷行），超過上限截斷並補「…」。
    static func excerpt(from body: String) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxExcerptLength else { return collapsed }
        return String(collapsed.prefix(maxExcerptLength)) + "…"
    }
}

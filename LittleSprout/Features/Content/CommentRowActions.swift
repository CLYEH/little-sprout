import Foundation

/// LS-218（依 LS-177 稿 `DUyg3`）：留言列的操作表動作組成——**刻意不重用**
/// `Services/Safety/ContentActions.swift` 的 `contentActions(for:...)`，因為兩者對「家庭管理者
/// 對別人的內容」這個身分組合給的答案不同：
///
/// - `contentActions(for:...)`（LS-189，日記／照片共用）：家庭管理者對別人的內容看到「檢舉」
///   ＋「封鎖」＋「移除這則內容」三列。`ContentActionsTests
///   .test_targetType_doesNotAffectActionComposition` 明確釘住「目標類型不影響動作組成」這個
///   LS-189 定案的契約，`.comment` 傳進去會拿到跟 `.diary` 一模一樣的三列——這是刻意的既有行為，
///   不能為了這張票的需求悄悄改掉那支共用函式（會讓那支回歸測試變成假陽性）。
/// - 留言列（本票）：`DUyg3` 稿面只有一列「移除這則留言」（danger），沒有「檢舉」「封鎖」
///   ——LS-177 Handoff Notes `QFvDu`：「與 LS-152 05 的差異只在 Action List 只有一列
///   『移除這則留言』，不含『檢舉』『封鎖』——這是刻意的範圍縮小：票文只要求『Owner 移除留言』，
///   未要求對留言本身的檢舉／封鎖動作，避免功能蔓延。」
///
/// 一般成員（非 owner、非作者）對別人的留言，動作組成與 `contentActions(for:...)` 的結果一致
/// （`[.report]`，作者已知再加 `[.block(...)]`）——這條分支延續 LS-189 現有行為，不是本票的
/// 新裁量（票文範圍 5：「一般成員→LS-189 05 操作表」）。
///
/// 純函式（不依賴 View／Store，同 `contentActions(for:...)` 的既有測試慣例，方便窮舉身分矩陣）。
func commentRowActions(
    authorID: UUID?, authorDisplayName: String, viewerRole: FamilyRole, viewerUserID: UUID
) -> [ContentAction] {
    if let authorID, authorID == viewerUserID {
        return [.deleteOwn]
    }
    if viewerRole == .owner {
        // `DUyg3`：Owner 對別人的留言只有單一 danger 列「移除這則留言」，不疊加檢舉／封鎖。
        return [.removeAsOwner]
    }
    var actions: [ContentAction] = [.report]
    if let authorID {
        actions.append(.block(memberID: authorID, memberName: authorDisplayName))
    }
    return actions
}

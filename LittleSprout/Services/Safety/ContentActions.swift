import Foundation

/// 內容操作表（`design/littlesprout.pen` `WgbNc`，票文範圍 1）要判斷「這則內容是誰的」——
/// 呼叫端（`DiaryDetailView` 等）組好這個值再交給 `contentActions(for:viewerRole:viewerUserID:
/// authorID:authorDisplayName:)`。
///
/// `headline`：操作表 Head Title 用的內容預覽（稿面示範是日記本文開頭加引號，例如
/// 「今天在溜滑梯上玩得好開心。」）；沒有可用文字預覽的目標（例如照片）由呼叫端傳入通用標籤
/// （例如「這張照片」）。
struct ContentActionTarget: Equatable, Sendable, Identifiable {
    let type: ContentTargetType
    let id: UUID
    let familyID: UUID
    let headline: String
}

/// 內容操作表的一列動作（`WgbNc` 三動作＋「自己的內容→刪除」，票文範圍 1）。
enum ContentAction: Equatable, Sendable {
    case report
    /// `memberID`／`memberName`：封鎖動作需要知道封鎖對象是誰（`block_user(p_family_id,
    /// p_blocked_id)`），`memberName` 同時用在稿面「封鎖陳志明」這種帶名字的列文案與 05d 確認
    /// 卡標題（`design/littlesprout.pen` `EXgzz`）。
    case block(memberID: UUID, memberName: String)
    case removeAsOwner
    case deleteOwn

    /// SF Symbol 對照（LS-152 Notes「SF Symbol 對照」段）：flag→flag.fill、
    /// user-x→person.fill.xmark、trash-2→trash（`removeAsOwner`／`deleteOwn` 共用，同
    /// `DeleteConfirmationSheet` 既有的刪除圖示）。
    var icon: String {
        switch self {
        case .report: "flag.fill"
        case .block: "person.fill.xmark"
        case .removeAsOwner, .deleteOwn: "trash"
        }
    }

    /// 稿面 `WgbNc` 示範文案：「檢舉這則內容」／「封鎖{name}」／「移除這則內容」；`deleteOwn`
    /// 本身不在 `WgbNc` demo 出現（那張示範態刻意呈現「viewer 是家庭管理者、且不是作者」的組合，
    /// 見 `contentActions` 文件註解），這裡的「刪除」是這一列本身的通用文案——實際刪除確認卡
    /// 的標題／內文由呼叫端接的 `DiaryDeleteConfirmationSheet`／`CommentDeleteConfirmationSheet`
    /// （LS-190）各自提供，這裡只需要一個夠清楚的動作列文字。
    var label: String {
        switch self {
        case .report: "檢舉這則內容"
        case .block(_, let memberName): "封鎖\(memberName)"
        case .removeAsOwner: "移除這則內容"
        case .deleteOwn: "刪除"
        }
    }

    /// 危險色（danger）列：移除／刪除；檢舉／封鎖維持一般文字色（同稿面 `WgbNc` 只有「移除這則
    /// 內容（Owner）」用 `$danger`，其餘兩動作是 `$text-secondary`）。
    var isDanger: Bool {
        switch self {
        case .report, .block: false
        case .removeAsOwner, .deleteOwn: true
        }
    }
}

/// 純函式（不依賴任何 Store／View，方便 XCTest 直接窮舉身分矩陣，同
/// `FamilyMemberActionVisibility.swift` 既有慣例）：依「這則內容是不是我自己的」「我是不是這個
/// 家庭的家庭管理者」「作者是誰、還查不查得到」決定要顯示哪些動作。
///
/// 對齊 LS-152 Notes 與票文範圍 1 的三條規則：
///   - 非作者 → 檢舉一律顯示。
///   - 非自己 → 封鎖此成員顯示（`docs/API.md` `block_user` 段：`p_blocked_id` 不驗證是否為該
///     家庭成員、也沒有排除家庭管理者的限制——封鎖家庭管理者本人一樣合法，不特殊處理）。
///   - 家庭管理者 → 移除內容顯示（`remove_content_as_owner` 純 owner 專用）。
///   - 自己的內容 → 只顯示刪除（不會同時看到檢舉／封鎖自己、也不會看到「移除」——那是給別人
///     內容用的管理動作，自己的內容用既有的 `DiaryDeleteConfirmationSheet`／
///     `CommentDeleteConfirmationSheet`）。
///
/// `authorID == nil`（例如作者已離開家庭、`profiles` 列被 `on delete set null`）時視為「不是我」
/// 但也無法封鎖（`block_user` 需要一個確定的 `p_blocked_id`）——只保留檢舉與（若我是家庭管理者）
/// 移除。
func contentActions(
    for target: ContentActionTarget,
    viewerRole: FamilyRole,
    viewerUserID: UUID,
    authorID: UUID?,
    authorDisplayName: String
) -> [ContentAction] {
    if let authorID, authorID == viewerUserID {
        return [.deleteOwn]
    }
    var actions: [ContentAction] = [.report]
    if let authorID {
        actions.append(.block(memberID: authorID, memberName: authorDisplayName))
    }
    if viewerRole == .owner {
        actions.append(.removeAsOwner)
    }
    return actions
}

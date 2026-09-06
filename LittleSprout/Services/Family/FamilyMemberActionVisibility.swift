import Foundation

/// LS-192：03 成員清單角色徽章文字——`.member`／`.viewer` 沿用 `InviteFamilyView+Role.swift`
/// 既有的「一般成員」「只能看」措辭（07a 角色選擇列）；`.owner` R2 修正為 Notes MN-1 定案的
/// 「家庭管理者」（R1 曾誤用「擁有者」，merge-review R1 M3：全稿角色詞彙定案是「家庭管理者／
/// 一般成員／只能看」，不是 Owner／擁有者）。
extension FamilyRole {
    var membersListDisplayLabel: String {
        switch self {
        case .owner: "家庭管理者"
        case .member: "一般成員"
        case .viewer: "只能看"
        }
    }

    /// 稿 `cmp/Role Pill`（`AqN3F`）三個角色 override 的圖示（lucide `crown`／`user`／`eye`），
    /// 對應本專案既有 SF Symbol 命名慣例（同 `Pill.swift` 既有呼叫端一律不加 `.fill` 的樣式）。
    var membersListIconName: String {
        switch self {
        case .owner: "crown"
        case .member: "person"
        case .viewer: "eye"
        }
    }
}

/// LS-192：03 成員清單「移除」「轉移家庭管理者」兩個動作的可見性——抽成不含 View 依賴的純
/// 函式，方便 XCTest 直接覆蓋「依角色決定動作是否可見」（票文範圍 5），不需要透過渲染
/// SwiftUI 視圖間接推論。
extension FamilyMember {
    /// Owner 對「其他」成員可以移除；不能移除自己——自己離開走另一顆「退出家庭」入口
    /// （03d／03e／03e 單人變體，見 `FamilyStore.leaveFlowCase`），不是成員列上的「移除」
    /// 動作（稿面 `yMNOt` 標題只會出現在別人的列）。
    func isRemovable(byRole myRole: FamilyRole, myUserID: UUID) -> Bool {
        myRole == .owner && userID != myUserID
    }

    /// Owner 對「其他」成員可以轉移家庭管理者身分；`transfer_ownership` RPC 本身不限制對方
    /// 角色（owner／member／viewer 皆可，見 docs/API.md §4），這裡與 RPC 一致，只排除「轉移
    /// 給自己」。
    func isTransferable(byRole myRole: FamilyRole, myUserID: UUID) -> Bool {
        myRole == .owner && userID != myUserID
    }
}

/// LS-192 R3（merge-review R2 M-A，orchestrator 裁決見 LS-192 comment
/// `af82ed61-7f07-4be2-a332-3b1ede49e5c3`）：「退出家庭」的三態分流。R2 之前
/// `mustTransferOwnershipBeforeLeaving`（`Bool`）把「唯一 owner 兼唯一成員」跟「不需要轉移
/// 就能退出」混成同一個 `false`，實際送出必然撞 `private.enforce_family_has_owner()`
/// （LS001，見該 migration「刻意不做的事」）——單人家庭「退出」在語意上等同「刪家庭」，唯一
/// 合理路徑是刪除帳號（LS-24），不是重試一次注定失敗的退出。獨立成第三態，讓
/// `FamilyMembersView.startLeaveFlow()` 對這個狀態完全不送出任何 DELETE 請求。
enum LeaveFlowCase: Equatable {
    /// 03d：一般退出確認——非 owner，或 owner 但家庭另有共同 owner（不會讓家庭懸空）。
    case leave
    /// 03e：唯一 owner、家庭還有其他成員——退出前必須先把家庭管理者身分轉移給其中一位。
    case mustTransferFirst
    /// 03e 單人變體：owner 且家庭只有自己一人——退出無意義，導向「帳號」→「刪除帳號」。
    /// 設計稿沒有獨立板（記入 LS-208 補板），版面沿用 `mustTransferFirst` 那張、只換文案並
    /// 隱藏「前往轉移」卡片，見 `MustTransferOwnershipFirstView`。
    case soleMember
}

/// 純函式（不依賴 `FamilyStore` 實例，方便 XCTest 直接窮舉三態）：依「呼叫者是不是 owner」
/// 「排除自己後還有幾位其他成員」「其他成員裡有沒有另一位 owner」決定退出流程分支，對齊
/// `private.enforce_ownership_transfer_before_leave()`（`supabase/migrations/
/// 20260905132350_family_ownership_guard.sql`）的判斷順序：非 owner 一律 `.leave`；
/// 排除自己後沒有其他成員 → `.soleMember`；其他成員裡已經有另一位 owner → `.leave`
/// （不會讓家庭懸空）；其餘（owner、有其他成員、其他成員都不是 owner）→ `.mustTransferFirst`。
func resolveLeaveFlowCase(isOwner: Bool, otherMembersCount: Int, hasOtherOwner: Bool) -> LeaveFlowCase {
    guard isOwner else { return .leave }
    guard otherMembersCount > 0 else { return .soleMember }
    return hasOtherOwner ? .leave : .mustTransferFirst
}

/// LS-192 R2（merge-review R1 B1／M1）：家庭成員管理四個動作（移除／轉移／退出）共用的
/// 錯誤碼→專屬文案分流——`AppError.userFacingMessage` 對 `.rejected` 一律回泛用的「無法完成
/// 這個操作。」，LS001／LS057～060 五碼在 UI 上完全無法區分（票文範圍 4／派工「LS0xx 映射」
/// 皆明訂要做）。同 `JoinCodePhase.swift` 用碼分流專屬態的既有慣例，這裡簡化成一個 message
/// 查詢：呼叫端用 `error.familyMemberActionMessage ?? error.userFacingMessage` 兜底。
extension AppError {
    /// B1：唯一 owner 退出／被移除有兩種觸發路徑——`LS057`（一般情況，`private.enforce_
    /// ownership_transfer_before_leave`）與 `LS001`（極端併發窗口——R3 之後，「唯一 owner
    /// 且唯一成員」已改走 `LeaveFlowCase.soleMember` 分支、不再送出 DELETE，見
    /// `resolveLeaveFlowCase` 文件註解——保留這個映射純粹是防禦性的，不是這條路徑本身還會被
    /// 觸發）都用 LS-152 Notes 錯誤文案表指定的同一句 03e 文案接住，不落回泛用訊息。M1：03c
    /// 轉移 Owner 的三個授權碼（LS058／LS059／LS060）也各自給出可行動的文案（換輸入沒有用，
    /// 但至少講清楚「重新整理成員列表」這個下一步）。
    var familyMemberActionMessage: String? {
        guard case .rejected(_, let code) = self else { return nil }
        switch code {
        case LSErrorCode.familyMustHaveOwner.rawValue, LSErrorCode.ownerMustTransferBeforeLeaving.rawValue:
            return "需要先轉移家庭管理者身分"
        case LSErrorCode.notFamilyOwner.rawValue:
            return "你已經不是這個家庭的管理者了，請重新整理成員列表。"
        case LSErrorCode.transferTargetNotMember.rawValue:
            return "對方已經不在這個家庭了，請重新整理成員列表。"
        case LSErrorCode.cannotTransferToSelf.rawValue:
            return "不能把家庭管理者身分轉移給自己。"
        default:
            return nil
        }
    }
}

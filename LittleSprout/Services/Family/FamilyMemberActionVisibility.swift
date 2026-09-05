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
    /// （03d／03e，見 `FamilyStore.mustTransferOwnershipBeforeLeaving`），不是成員列上的
    /// 「移除」動作（稿面 `yMNOt` 標題只會出現在別人的列）。
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

/// LS-192 R2（merge-review R1 B1／M1）：家庭成員管理四個動作（移除／轉移／退出）共用的
/// 錯誤碼→專屬文案分流——`AppError.userFacingMessage` 對 `.rejected` 一律回泛用的「無法完成
/// 這個操作。」，LS001／LS057～060 五碼在 UI 上完全無法區分（票文範圍 4／派工「LS0xx 映射」
/// 皆明訂要做）。同 `JoinCodePhase.swift` 用碼分流專屬態的既有慣例，這裡簡化成一個 message
/// 查詢：呼叫端用 `error.familyMemberActionMessage ?? error.userFacingMessage` 兜底。
extension AppError {
    /// B1：唯一 owner 退出／被移除有兩種觸發路徑——`LS057`（一般情況，`private.enforce_
    /// ownership_transfer_before_leave`）與 `LS001`（極端併發窗口，或「唯一 owner 且唯一
    /// 成員」時 client 端 `mustTransferOwnershipBeforeLeaving` 誤判為不需要轉移、實際送出
    /// 撞到既有的 `private.enforce_family_has_owner`）——兩者都用 LS-152 Notes 錯誤文案表
    /// 指定的同一句 03e 文案接住，不落回泛用訊息。M1：03c 轉移 Owner 的三個授權碼
    /// （LS058／LS059／LS060）也各自給出可行動的文案（換輸入沒有用，但至少講清楚「重新整理
    /// 成員列表」這個下一步）。
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

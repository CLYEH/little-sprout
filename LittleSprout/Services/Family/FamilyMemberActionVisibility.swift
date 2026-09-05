import Foundation

/// LS-192：03 成員清單角色徽章文字——`.member`／`.viewer` 沿用 `InviteFamilyView+Role.swift`
/// 既有的「一般成員」「只能看」措辭（07a 角色選擇列），`.owner` 是本票新增的顯示情境
/// （07 從未把 owner 列成可選角色），採「擁有者」對齊 docs/API.md 散文的既有用詞。
extension FamilyRole {
    var membersListDisplayLabel: String {
        switch self {
        case .owner: "擁有者"
        case .member: "一般成員"
        case .viewer: "只能看"
        }
    }
}

/// LS-192：03 成員清單「移除」「轉移 Owner」兩個動作的可見性——抽成不含 View 依賴的純函式，
/// 方便 XCTest 直接覆蓋「依角色決定動作是否可見」（票文範圍 5），不需要透過渲染 SwiftUI
/// 視圖間接推論。
extension FamilyMember {
    /// Owner 對「其他」成員可以移除；不能移除自己——自己離開走另一顆「退出家庭」入口
    /// （03d／03e，見 `FamilyStore.mustTransferOwnershipBeforeLeaving`），不是成員列上的
    /// 「移除」動作（稿面 `yMNOt` 標題只會出現在別人的列）。
    func isRemovable(byRole myRole: FamilyRole, myUserID: UUID) -> Bool {
        myRole == .owner && userID != myUserID
    }

    /// Owner 對「其他」成員可以轉移 owner 身份；`transfer_ownership` RPC 本身不限制對方角色
    /// （owner／member／viewer 皆可，見 docs/API.md §4），這裡與 RPC 一致，只排除「轉移給
    /// 自己」。
    func isTransferable(byRole myRole: FamilyRole, myUserID: UUID) -> Bool {
        myRole == .owner && userID != myUserID
    }
}

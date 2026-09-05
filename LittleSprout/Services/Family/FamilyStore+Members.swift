import Foundation

/// LS-192：03 家庭成員管理（清單／移除／轉移 Owner／退出）——拆成獨立檔案的理由同
/// `FamilyStore+JoinRequests.swift` 檔頭註解（`FamilyStore.swift` 逼近 SwiftLint `file_length`
/// 上限）。狀態宣告在 `FamilyStore.swift`（Swift extension 不能加 stored property）。
extension FamilyStore {
    /// 呼叫者自己在 `members` 裡的角色——`FamilyMembersView` 用它判斷「移除」「轉移 Owner」
    /// 動作的可見性（見 `FamilyMemberActionVisibility.swift`）。`members` 還沒查回來，或
    /// 呼叫者不在清單裡（理論上不會，能看到這個畫面代表已經在家庭裡）時回 nil。
    var myRole: FamilyRole? {
        guard let userID = ownerUserID else { return nil }
        return members.first(where: { $0.userID == userID })?.role
    }

    #if DEBUG
    /// 只給 SwiftUI `#Preview`／`TapTargetGateHarness` 用：同步把 `members` 設成給定值，不需要
    /// 真的走一次 async `refreshMembers()`（同 `seedMyFamilyForPreview` 的既有作法）。`members`
    /// 不是 `private(set)`（見 `FamilyStore.swift` 屬性宣告文件註解），這裡可以直接加在這個
    /// extension 檔案，不需要動主檔。
    func seedMembersForPreview(_ members: [FamilyMember]) {
        self.members = members
    }
    #endif

    /// `FamilyMembersView` 進場查詢；03-iPad／AX3 共用同一份資料，不需要另外的變體。
    ///
    /// R2（merge-review R1 m7，PLAUSIBLE）：await 前後核對 `myFamily?.id`，同
    /// `FamilyStore.refreshQuota()` 既有理由——這段 RTT 期間若換了家庭（退出家庭後
    /// `leaveFamily()` 已把 `myFamily` 歸零，或切帳號後 `syncOwner()` 整份 `reset()`），這裡
    /// 查到的結果已經過期，直接丟棄、不覆寫，避免上一個家庭的成員清單寫進下一個家庭的
    /// `members`。
    @discardableResult
    func refreshMembers() async -> [FamilyMember] {
        guard !membersState.isSubmitting else { return members }
        guard let familyID = myFamily?.id else { return members }
        membersState = .submitting
        do {
            let result = try await apiClient.listMembers(familyID: familyID)
            guard myFamily?.id == familyID else {
                membersState = .idle
                return members
            }
            members = result
            membersState = .success
            await refreshAvatarSignedURLs()
        } catch {
            guard myFamily?.id == familyID else {
                membersState = .idle
                return members
            }
            membersState = .failure(AppError.map(error))
        }
        return members
    }

    func resetMemberActionState() {
        guard case .failure = memberActionState else { return }
        memberActionState = .idle
    }

    /// 移除成員（03b，owner 對他人）——成功後就地從 `members` 移除，不整份重查（同排序穩定，
    /// 且省一次網路來回）。
    @discardableResult
    func removeMember(userID: UUID) async -> Bool {
        guard !memberActionState.isSubmitting else { return false }
        guard let familyID = myFamily?.id else { return false }
        memberActionState = .submitting
        do {
            try await apiClient.removeMember(familyID: familyID, userID: userID)
            members.removeAll { $0.userID == userID }
            memberActionState = .success
            return true
        } catch {
            memberActionState = .failure(AppError.map(error))
            return false
        }
    }

    /// 轉移 owner 身份（03c）——成功後用 RPC 回傳的新角色對就地更新兩列，不整份重查。
    @discardableResult
    func transferOwnership(toUserID: UUID) async -> Bool {
        guard !memberActionState.isSubmitting else { return false }
        guard let familyID = myFamily?.id else { return false }
        memberActionState = .submitting
        do {
            let result = try await apiClient.transferOwnership(familyID: familyID, toUserID: toUserID)
            applyTransferResult(result)
            memberActionState = .success
            return true
        } catch {
            memberActionState = .failure(AppError.map(error))
            return false
        }
    }

    private func applyTransferResult(_ result: TransferOwnershipResult) {
        members = members.map { member in
            if member.userID == result.fromUserID {
                return FamilyMember(
                    userID: member.userID, role: result.fromRole,
                    displayName: member.displayName, avatarURL: member.avatarURL
                )
            }
            if member.userID == result.toUserID {
                return FamilyMember(
                    userID: member.userID, role: result.toRole,
                    displayName: member.displayName, avatarURL: member.avatarURL
                )
            }
            return member
        }.sorted { lhs, rhs in
            if lhs.role.sortRank != rhs.role.sortRank { return lhs.role.sortRank < rhs.role.sortRank }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// 退出家庭（03d／03e）——對 `family_members` 刪除呼叫者自己這一列，跟 owner 移除別人是
    /// 同一支 DB 操作（`removeMember`），差別只在 `userID` 是不是自己。成功後把 `myFamily`
    /// 歸零，root routing（`AuthenticatedGate`）下一次重繪會自然切回三岔路（LS-18），不需要
    /// 任何手動導航；同時清掉 `members`——同一個 session 內若之後建立／加入另一個家庭，不該
    /// 沿用剛離開那個家庭的成員清單殘影。
    @discardableResult
    func leaveFamily() async -> Bool {
        guard let userID = ownerUserID else { return false }
        let success = await removeMember(userID: userID)
        if success {
            clearMyFamilyAfterLeaving()
            members = []
            membersState = .idle
        }
        return success
    }

    /// 03d／03e 分流的 client 端預判——伺服器 `LS057` 為準（見 `AppError` 文件註解），這裡只是
    /// 「按下退出前」就能直接顯示哪張確認稿，不需要先送一次註定失敗的請求才知道。判斷式對齊
    /// `private.enforce_ownership_transfer_before_leave()`（`supabase/migrations/
    /// 20260905132350_family_ownership_guard.sql`）：呼叫者是 owner、家庭裡沒有其他 owner、
    /// 但還有其他成員 → 必須先轉移（03e）；其餘情況（包含唯一成員自己）→ 一般退出確認（03d）。
    var mustTransferOwnershipBeforeLeaving: Bool {
        guard let userID = ownerUserID else { return false }
        guard let myself = members.first(where: { $0.userID == userID }), myself.role == .owner else { return false }
        let others = members.filter { $0.userID != userID }
        guard !others.isEmpty else { return false }
        return !others.contains { $0.role == .owner }
    }
}

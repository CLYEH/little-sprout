import Foundation

/// 07 邀請家人（建立邀請碼／查詢現有邀請碼）用到的 `FamilyStore` 動作——拆成獨立檔案
/// （merge-review R2 B3）：`FamilyStore.swift` 與 `SettingsView.swift` 同一天各自被兩張票
/// （本票／LS-210）疊加壓到 SwiftLint `file_length` 400 行上限，這裡拉開餘裕，理由同
/// `FamilyStore+JoinRequests.swift` 檔頭既有先例。純搬移，不改行為：`createInviteState`／
/// `lookupInviteState`／`latestInvite` 因此不再是 `private(set)`（狀態本身仍宣告在主檔，
/// Swift extension 不能新增 stored property，見主檔屬性宣告處）。
extension FamilyStore {
    /// 建立邀請碼；期限與次數固定用 `defaultInviteValidityDays`／`defaultInviteMaxUses`
    /// （見主檔常數註解），畫面只讓使用者選角色。沒有家庭時直接回傳失敗，不呼叫後端——
    /// 這裡的 `.rejected` 不對應任何後端錯誤碼，是呼叫端自己組錯前置條件的訊號。
    ///
    /// R1 F2：若目前已經有一支 `latestInvite`（表示這是「重新產生」，不是第一次產生），
    /// 先呼叫 `revokeInvite` 撤銷它再建立新的——`InviteFamilyView` 的重新產生確認對話框
    /// 明講「舊碼就不能再用了」，後端沒有 `revoke_invite` RPC，唯一能讓那句話成真的路徑
    /// 是 DELETE（`supabase/migrations/20260823040000_invites_write_path.sql` §3／LS-37
    /// 收斂註記）。撤銷失敗就整個 throw、不繼續建立新碼——不能讓 owner 帳上同時存在一支
    /// 「已經跟使用者說作廢了、其實還活著」的舊碼與一支新碼。第一次產生（`latestInvite`
    /// 為 nil）不受影響，行為與過去相同。
    ///
    /// R2 N1（情境 A）：多擋一個 `lookupInviteState.isSubmitting`——`refreshLatestInvite()`
    /// 進場查詢還在飛的時候，`latestInvite` 可能仍是 nil（還沒查回來），這裡若照跑會把
    /// revoke 分支跳過、平白多建一支永遠撤不掉的碼（查詢回來後會用它查到的舊碼覆寫
    /// `latestInvite`，新建的這支從此在畫面上消失但 DB 裡仍然活著）。跟查詢方向的 guard
    /// （見 `refreshLatestInvite`）互相檢查對方的 `isSubmitting`，兩者互斥。
    @discardableResult
    func createInvite(role: FamilyRole) async -> String? {
        guard !createInviteState.isSubmitting else { return nil }
        guard !lookupInviteState.isSubmitting else { return nil }
        guard let familyID = myFamily?.id else {
            createInviteState = .failure(.rejected(message: "沒有家庭可以建立邀請碼", code: nil))
            return nil
        }
        createInviteState = .submitting
        do {
            if let existingID = latestInvite?.id {
                try await apiClient.revokeInvite(id: existingID)
                latestInvite = nil
            }
            let expiresAt = Date().addingTimeInterval(TimeInterval(Self.defaultInviteValidityDays) * 86400)
            let record = try await apiClient.createInvite(
                familyID: familyID,
                role: role,
                expiresAt: expiresAt,
                maxUses: Self.defaultInviteMaxUses
            )
            latestInvite = GeneratedInvite(record: record)
            createInviteState = .success
            return record.code
        } catch {
            createInviteState = .failure(AppError.map(error))
            return nil
        }
    }

    func resetCreateInviteState() {
        guard case .failure = createInviteState else { return }
        createInviteState = .idle
    }

    /// 07 進場先查這個家庭現有有沒有一支還有效的邀請碼（未過期、還有名額）——R1 F4：過去
    /// 每次重開 app、`latestInvite` 隨 store 生命週期消失就會回到空狀態，owner 因此以為自己
    /// 沒有邀請碼、再產生一支，疊上 F2（重新產生才會撤銷舊碼）就會讓好幾支碼同時有效。
    /// `InviteFamilyView.onAppear` 呼叫。
    ///
    /// R2 N1 訂正：查詢失敗現在寫自己的 `lookupInviteState`，不再借用 `createInviteState`
    /// ——舊寫法會在使用者剛按下「產生邀請碼」（`createInviteState = .submitting`）之後被
    /// 這裡的 catch 蓋成 `.failure`，讓 `createInvite` 開頭的 in-flight guard 形同失效，使用者
    /// 看到錯誤再按一次就會兩支 `create_invite` 併發（情境 C）。`InviteFamilyView` 依
    /// `InvitePhase` 分開顯示「查詢中」「查詢失敗」，兩者都不會顯示可按的「產生邀請碼」。
    ///
    /// 三道防線缺一不可：
    /// 1. 前置 guard 擋掉跟 `createInvite` 的並發（互斥，情境 A／C）。
    /// 2. await 之後重新核對 `myFamily?.id` 與 `createInviteState`——這段 RTT 期間若
    ///    `syncOwner` 把 store 換成別的使用者／家庭，或使用者已經成功產生了新碼，這裡查到的
    ///    結果已經過期，直接丟棄、不覆寫（情境 A 的更窄變體：A 查詢在 B 登入後才回來）。
    /// 3. `InviteFamilyView` 在查詢中／查詢失敗兩態都不顯示「產生邀請碼」（見 `InvitePhase`），
    ///    UI 層再擋一次，不只靠 store 的 guard。
    @discardableResult
    func refreshLatestInvite() async -> GeneratedInvite? {
        guard !createInviteState.isSubmitting else { return latestInvite }
        guard !lookupInviteState.isSubmitting else { return latestInvite }
        guard let familyID = myFamily?.id else { return nil }
        lookupInviteState = .submitting
        do {
            let record = try await apiClient.fetchLatestActiveInvite(familyID: familyID)
            guard isResultStillRelevant(familyID: familyID) else {
                // 結果過期：不覆寫 `latestInvite`，也不留一個永遠不會再被改的 `.submitting`
                // 卡住畫面／擋住下一次 `createInvite`——歸零回中性的 `.idle`。
                lookupInviteState = .idle
                return latestInvite
            }
            latestInvite = record.map(GeneratedInvite.init(record:))
            lookupInviteState = .success
        } catch {
            guard isResultStillRelevant(familyID: familyID) else {
                lookupInviteState = .idle
                return latestInvite
            }
            lookupInviteState = .failure(AppError.map(error))
        }
        return latestInvite
    }

    /// `refreshLatestInvite` 的 await 前後核對——見該方法文件註解第 2 點。`familyID` 不同代表
    /// 換了使用者／家庭（`syncOwner` 已經 `reset()` 過，繼續寫回去就是把舊使用者查到的碼塞進
    /// 新使用者的 store）；`createInviteState.isSubmitting` 理論上因為前置 guard 互斥不會在
    /// 查詢飛行期間變 true——這裡多留一道防線，未來若有人不小心鬆動 guard，也不會靜默覆寫。
    private func isResultStillRelevant(familyID: UUID) -> Bool {
        myFamily?.id == familyID && !createInviteState.isSubmitting
    }
}

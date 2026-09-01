import Foundation
import Observation

/// Family 相關非同步操作共用的狀態機（LS-107）：`idle`→尚未開始、`submitting`→呼叫中
/// （in-flight）、`success`→上一次呼叫成功、`failure`→上一次呼叫失敗並帶對映後的
/// `AppError`（供 UI 依四層文法挑文案，見 `AppError.userFacingMessage`）。`FamilyStore` 的
/// 三個非同步動作（查詢我的家庭／建立家庭／建立邀請碼）各自持有一份，互不干擾。
enum FamilyOperationState: Equatable {
    case idle
    case submitting
    case success
    case failure(AppError)

    var isSubmitting: Bool {
        self == .submitting
    }
}

/// 已產生的邀請碼——R1 F2/F4 訂正：`create_invite` RPC 只回傳 `code`，但 `id`／`usedCount`
/// 現在一律從 `invites` 表反查回來（`FamilyAPIClient.createInvite` 文件註解），不再是「呼叫端
/// 自己組出來、剛產生完必為 0」的假值。`id` 是撤銷（`revokeInvite`）需要的鍵；`usedCount` 是
/// F4「還可用 N 次」要用真實剩餘量，兩者都不能只靠呼叫端自己組。
struct GeneratedInvite: Equatable, Sendable {
    let id: UUID
    let code: String
    let role: FamilyRole
    let expiresAt: Date
    let maxUses: Int
    let usedCount: Int

    init(id: UUID, code: String, role: FamilyRole, expiresAt: Date, maxUses: Int, usedCount: Int) {
        self.id = id
        self.code = code
        self.role = role
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        self.usedCount = usedCount
    }

    init(record: InviteRecord) {
        self.init(
            id: record.id,
            code: record.code,
            role: record.role,
            expiresAt: record.expiresAt,
            maxUses: record.maxUses,
            usedCount: record.usedCount
        )
    }

    /// 07 Pill「還可用 N 次」要顯示的值——R1 F4：過去這裡曾經直接顯示 `maxUses`，
    /// 永遠不會反映真的用掉幾次。`max(0, ...)`：`usedCount` 理論上不會大於 `maxUses`
    /// （DB `invites_uses_within_max` CHECK 約束），這裡只是防禦性地不顯示負數。
    var remainingUses: Int {
        max(0, maxUses - usedCount)
    }
}

/// 把 `FamilyAPIClient` 包成 `@Observable`，讓三岔路／建立家庭／邀請家人三個畫面能直接讀
/// 狀態驅動重繪（同 `AuthStore` 之於 `AuthService` 的角色，見該檔文件）。
///
/// Root routing（`RootView`）用 `myFamily` 判斷「已登入但無家庭」該不該進三岔路；建立家庭
/// 成功後這裡的 `myFamily` 會被直接設成新家庭，root routing 下一次重繪就會自然切換到已登入
/// 主畫面——不需要任何手動導航呼叫（LS-18 comment `1fce1645`：不可重建 store 而不重建
/// service，這個 store 由 `LittleSproutApp` 建一次、隨 app 存活，`AuthenticatedGate` 之後
/// 每次重繪都讀同一份）。R1 F1：「隨 app 存活」只解決了 store 該不該重建的問題，換使用者時
/// 仍必須靠 `syncOwner(to:)` 主動歸零——見該方法文件註解。
@MainActor
@Observable
final class FamilyStore {
    // LS-108：不是 `private`——`FamilyStore+JoinRequests.swift` 的加入路徑方法（另一個檔案的
    // extension）需要用它打 request_join／approve_join 等 RPC；Swift 的 `private` 存取層級只到
    // 「同檔案」，跨檔案 extension 碰不到。退而求其次用預設的 internal（模組內可讀，對外
    // target 沒有暴露任何新表面，跟這個型別其餘所有狀態的可見度一致）。
    let apiClient: FamilyAPIClient

    private(set) var myFamily: Family?
    private(set) var lookupState: FamilyOperationState = .idle
    private(set) var createFamilyState: FamilyOperationState = .idle
    private(set) var createInviteState: FamilyOperationState = .idle
    /// R2 N1：`refreshLatestInvite()` 進場查詢的狀態，跟 `createInviteState`（使用者按「產生
    /// 邀請碼」）分開存放——過去兩個動作共寫 `createInviteState`，查詢失敗會把使用者剛按下的
    /// `.submitting` 蓋成 `.failure`，讓 `createInvite` 開頭的 in-flight guard 形同失效（R2
    /// 情境 C）。分開之後，`InviteFamilyView` 才能在「查詢中」「查詢失敗」顯示跟「產生中」
    /// 「產生失敗」不同的畫面（見 `InvitePhase`），且 `createInvite`／`refreshLatestInvite`
    /// 互相檢查對方的 `isSubmitting` 就能做到寫入互斥（見兩支方法文件註解）。
    private(set) var lookupInviteState: FamilyOperationState = .idle
    private(set) var latestInvite: GeneratedInvite?

    /// LS-113：剛建立完家庭，還沒決定要不要建立第一個寶貝檔案——`RootView` 依這個旗標用
    /// `.fullScreenCover` 蓋一層 `CreateChildView`（08）在主畫面之上，讓「建立家庭後可接、
    /// 可跳過」的寶貝建檔步驟接上（見 `CreateChildView` 文件註解）。`CreateChildView` 呼叫
    /// 環境 `dismiss()` 時，`.fullScreenCover(isPresented:)` 的雙向 binding 會自動把這裡寫回
    /// `false`，不需要額外的完成回呼。
    private(set) var showsChildOnboarding = false

    // LS-108 加入路徑（申請人：request_join／get_my_join_request／withdraw_join；owner：
    // list_join_requests／approve_join／reject_join）——狀態宣告在這裡（Swift extension 不能
    // 加 stored property），對應的方法拆去 `FamilyStore+JoinRequests.swift`（主檔已經逼近
    // SwiftLint `file_length` 400 行上限）。不是 `private(set)`：理由同上方 `apiClient`。
    var requestJoinState: FamilyOperationState = .idle
    var myJoinRequest: MyJoinRequest?
    var withdrawJoinState: FamilyOperationState = .idle
    var listJoinRequestsState: FamilyOperationState = .idle
    var pendingJoinRequests: [PendingJoinRequest] = []
    var joinRequestActionError: AppError?
    var processingJoinRequestIDs: Set<UUID> = []

    /// 目前這份狀態是查給哪個使用者看的——R1 F1：`FamilyStore` 是 app 層單例、隨 app 存活，
    /// 單純登出不會重置它。`syncOwner(to:)` 拿它跟 `AuthenticatedGate` 傳進來的
    /// `authStore.session?.userID` 比對，不同就代表換人了（已登入狀態下切換帳號），必須整份
    /// 歸零再視情況重查，否則第二位登入者會直接沿用第一位的 `myFamily`／`latestInvite`。
    /// 登出清理走另一條路徑，見 `reset()` 呼叫端（`SettingsView.signOut()`）與 R2 N5。
    private(set) var ownerUserID: UUID?

    /// 07 邀請碼「示意值維持 7 天 / 5 次（沿用既定決策）」——見 design/littlesprout.pen
    /// Handoff Notes「N LS-18 家庭」06b/06c 段；07/07a 沒有 UI 讓使用者自訂期限與次數。
    static let defaultInviteValidityDays = 7
    static let defaultInviteMaxUses = 5

    init(apiClient: FamilyAPIClient) {
        self.apiClient = apiClient
    }

    #if DEBUG
    /// 只給 SwiftUI `#Preview`／LS-95 `tap-target-check` harness 用：同步把 `myFamily` 設成
    /// 給定值，不需要真的走一次 async fetch。`myFamily` 是 `private(set)`（同檔案才能寫），
    /// 這支方法因此只能加在這裡，不能加在別檔案的 extension（見 `PreviewFamilyAPIClient.swift`
    /// 的 `FamilyStore.preview(withFamily:)`，那邊呼叫這支）。
    ///
    /// merge-review R1 M1(b)：`SettingsView` 的「邀請家人」列只在 `myFamily != nil` 才渲染
    /// （LS-107），若靠 `.task` 之類非同步載入才能看到「已有家庭」狀態，UI test 的量測 snapshot
    /// 有機會取在載入完成之前（同 B1 (d) 的時序問題）——這裡改成建構時就同步賦值，沒有這個
    /// 時序窗口。
    func seedMyFamilyForPreview(_ family: Family) {
        myFamily = family
    }
    #endif

    /// R1 F1：`AuthenticatedGate` 用 `.task(id: authStore.session?.userID)` 驅動這支——
    /// id 跟 `ownerUserID` 不同（含首次登入、含已登入狀態下切換帳號）就先整份歸零再視情況
    /// 重查；同一個使用者的其餘重繪（例如 `scenePhase` 觸發的 session snapshot 刷新造成
    /// `AuthenticatedGate` 重新求值）id 不變，不會白白再打一次網路。
    ///
    /// R2 N5：登出（`userID == nil`）這個分支在 `AuthenticatedGate` 這條路徑上不會被呼叫到
    /// ——`authStore.isAuthenticated()` 變 false 時 `AuthenticatedGate` 整個從 `RootView` 的
    /// 畫面樹移除，`.task(id:)` 只會被取消，不會用 `id: nil` 重跑一次（見 `RootView.swift`
    /// `AuthenticatedGate` 文件註解）。`guard userID != nil else { return nil }` 這條分支目前
    /// 只在直接呼叫這支方法的測試裡被走到；登出時真正的清理入口是 `SettingsView.signOut()`
    /// 成功後呼叫的 `reset()`。
    ///
    /// 刻意不放進 `refreshMyFamily()` 裡：那支是「查詢」動作本身，換人與否是呼叫端
    /// （root routing）才知道的事，混在一起會讓 `refreshMyFamily` 多一個隱藏前提。
    @discardableResult
    func syncOwner(to userID: UUID?) async -> Family? {
        guard userID != ownerUserID else { return myFamily }
        reset()
        ownerUserID = userID
        guard userID != nil else { return nil }
        return await refreshMyFamily()
    }

    /// 把三個動作的狀態與已查到的資料全部歸零——換使用者（見 `syncOwner`）或登出時呼叫。
    func reset() {
        ownerUserID = nil
        myFamily = nil
        latestInvite = nil
        lookupState = .idle
        createFamilyState = .idle
        createInviteState = .idle
        lookupInviteState = .idle
        showsChildOnboarding = false
        resetJoinRequestsState()
    }

    /// 查詢呼叫者目前所屬的家庭；`RootView` 在「已登入」但還不確定有沒有家庭時呼叫一次。
    /// R1 F8：補上跟另外兩個動作對稱的 in-flight guard——`syncOwner` 落地後這裡多了一個
    /// 觸發點，兩個併發呼叫的完成順序原本會決定最終 `myFamily`，用 guard 讓後到的呼叫
    /// 直接回傳目前值，不重新發一次請求跟前一個賽跑。
    @discardableResult
    func refreshMyFamily() async -> Family? {
        guard !lookupState.isSubmitting else { return myFamily }
        lookupState = .submitting
        do {
            myFamily = try await apiClient.fetchMyFamily()
            lookupState = .success
        } catch {
            lookupState = .failure(AppError.map(error))
        }
        return myFamily
    }

    /// 建立家庭；成功後直接把 `myFamily` 設成新家庭，root routing 因此自動離開三岔路
    /// （見本型別文件註解）。`guard !createFamilyState.isSubmitting`：擋掉使用者連點兩下
    /// 造成的重複送出（in-flight disable，不是驗證型 disable）。
    @discardableResult
    func createFamily(name: String) async -> Bool {
        guard !createFamilyState.isSubmitting else { return false }
        createFamilyState = .submitting
        do {
            let family = try await apiClient.createFamily(name: name)
            myFamily = family
            createFamilyState = .success
            // LS-113：接上「建立家庭後可接、可跳過」的寶貝建檔步驟——見 `showsChildOnboarding`
            // 文件註解。
            showsChildOnboarding = true
            return true
        } catch {
            createFamilyState = .failure(AppError.map(error))
            return false
        }
    }

    /// `RootView` 的 `.fullScreenCover` 在使用者建立寶貝檔案成功或按「之後再說」（`dismiss()`
    /// 觸發 binding 的 `set` 分支）時呼叫，把旗標寫回 `false`。
    func dismissChildOnboarding() {
        showsChildOnboarding = false
    }

    /// 重新導航回這個畫面時，把上一次失敗的殘影清掉——`createFamilyState` 是 store 層的狀態、
    /// 隨 app 存活，不會像 View-local `@State` 一樣每次進畫面自動重置。
    func resetCreateFamilyState() {
        guard case .failure = createFamilyState else { return }
        createFamilyState = .idle
    }

    /// 建立邀請碼；期限與次數固定用 `defaultInviteValidityDays`／`defaultInviteMaxUses`
    /// （見上方常數註解），畫面只讓使用者選角色。沒有家庭時直接回傳失敗，不呼叫後端——
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

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
    private let apiClient: FamilyAPIClient

    private(set) var myFamily: Family?
    private(set) var lookupState: FamilyOperationState = .idle
    private(set) var createFamilyState: FamilyOperationState = .idle
    private(set) var createInviteState: FamilyOperationState = .idle
    private(set) var latestInvite: GeneratedInvite?

    /// 目前這份狀態是查給哪個使用者看的——R1 F1：`FamilyStore` 是 app 層單例、隨 app 存活，
    /// 單純登出不會重置它。`syncOwner(to:)` 拿它跟 `AuthenticatedGate` 傳進來的
    /// `authStore.session?.userID` 比對，不同就代表換人了（含登出＝變 nil），必須整份歸零
    /// 再視情況重查，否則第二位登入者會直接沿用第一位的 `myFamily`／`latestInvite`。
    private(set) var ownerUserID: UUID?

    /// 07 邀請碼「示意值維持 7 天 / 5 次（沿用既定決策）」——見 design/littlesprout.pen
    /// Handoff Notes「N LS-18 家庭」06b/06c 段；07/07a 沒有 UI 讓使用者自訂期限與次數。
    static let defaultInviteValidityDays = 7
    static let defaultInviteMaxUses = 5

    init(apiClient: FamilyAPIClient) {
        self.apiClient = apiClient
    }

    /// R1 F1：`AuthenticatedGate` 用 `.task(id: authStore.session?.userID)` 驅動這支——
    /// id 跟 `ownerUserID` 不同（含首次登入、含登出時變 nil）就先整份歸零再視情況重查；
    /// 同一個使用者的其餘重繪（例如 `scenePhase` 觸發的 session snapshot 刷新造成
    /// `AuthenticatedGate` 重新求值）id 不變，不會白白再打一次網路。
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
            return true
        } catch {
            createFamilyState = .failure(AppError.map(error))
            return false
        }
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
    @discardableResult
    func createInvite(role: FamilyRole) async -> String? {
        guard !createInviteState.isSubmitting else { return nil }
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
    /// 查詢失敗（多半網路）借用 `createInviteState` 顯示錯誤——這裡跟「建立邀請碼」概念上
    /// 都是「這個家庭的邀請碼」狀態，`InviteFamilyView` 本來就有 `errorRow` 掛在這個狀態
    /// 下面；使用者可以直接按「產生邀請碼」重試，`createInvite` 一開始就會把這個狀態蓋成
    /// `.submitting`，不需要另外呼叫 reset。
    @discardableResult
    func refreshLatestInvite() async -> GeneratedInvite? {
        guard let familyID = myFamily?.id else { return nil }
        do {
            latestInvite = try await apiClient.fetchLatestActiveInvite(familyID: familyID)
                .map(GeneratedInvite.init(record:))
        } catch {
            createInviteState = .failure(AppError.map(error))
        }
        return latestInvite
    }
}

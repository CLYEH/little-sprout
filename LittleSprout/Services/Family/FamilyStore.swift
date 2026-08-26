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

/// 已產生的邀請碼——`createInvite` RPC 只回傳 `code`（見 `FamilyAPIClient.createInvite`
/// 文件註解），`expiresAt`／`maxUses` 是呼叫端自己選定、送出去的參數，剛產生完的當下
/// `usedCount` 必為 0，不需要另外查一次 `invites` 表就能把三者一起顯示給使用者看。
struct GeneratedInvite: Equatable, Sendable {
    let code: String
    let role: FamilyRole
    let expiresAt: Date
    let maxUses: Int
}

/// 把 `FamilyAPIClient` 包成 `@Observable`，讓三岔路／建立家庭／邀請家人三個畫面能直接讀
/// 狀態驅動重繪（同 `AuthStore` 之於 `AuthService` 的角色，見該檔文件）。
///
/// Root routing（`RootView`）用 `myFamily` 判斷「已登入但無家庭」該不該進三岔路；建立家庭
/// 成功後這裡的 `myFamily` 會被直接設成新家庭，root routing 下一次重繪就會自然切換到已登入
/// 主畫面——不需要任何手動導航呼叫（LS-18 comment `1fce1645`：不可重建 store 而不重建
/// service，這個 store 由 `LittleSproutApp` 建一次、隨 app 存活，`AuthenticatedGate` 之後
/// 每次重繪都讀同一份）。
@MainActor
@Observable
final class FamilyStore {
    private let apiClient: FamilyAPIClient

    private(set) var myFamily: Family?
    private(set) var lookupState: FamilyOperationState = .idle
    private(set) var createFamilyState: FamilyOperationState = .idle
    private(set) var createInviteState: FamilyOperationState = .idle
    private(set) var latestInvite: GeneratedInvite?

    /// 07 邀請碼「示意值維持 7 天 / 5 次（沿用既定決策）」——見 design/littlesprout.pen
    /// Handoff Notes「N LS-18 家庭」06b/06c 段；07/07a 沒有 UI 讓使用者自訂期限與次數。
    static let defaultInviteValidityDays = 7
    static let defaultInviteMaxUses = 5

    init(apiClient: FamilyAPIClient) {
        self.apiClient = apiClient
    }

    /// 查詢呼叫者目前所屬的家庭；`RootView` 在「已登入」但還不確定有沒有家庭時呼叫一次。
    @discardableResult
    func refreshMyFamily() async -> Family? {
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
    @discardableResult
    func createInvite(role: FamilyRole) async -> String? {
        guard !createInviteState.isSubmitting else { return nil }
        guard let familyID = myFamily?.id else {
            createInviteState = .failure(.rejected(message: "沒有家庭可以建立邀請碼", code: nil))
            return nil
        }
        createInviteState = .submitting
        let expiresAt = Date().addingTimeInterval(TimeInterval(Self.defaultInviteValidityDays) * 86400)
        do {
            let code = try await apiClient.createInvite(
                familyID: familyID,
                role: role,
                expiresAt: expiresAt,
                maxUses: Self.defaultInviteMaxUses
            )
            latestInvite = GeneratedInvite(
                code: code, role: role, expiresAt: expiresAt, maxUses: Self.defaultInviteMaxUses
            )
            createInviteState = .success
            return code
        } catch {
            createInviteState = .failure(AppError.map(error))
            return nil
        }
    }

    func resetCreateInviteState() {
        guard case .failure = createInviteState else { return }
        createInviteState = .idle
    }
}

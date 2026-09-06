import Foundation
import Observation

/// `EULAStore` 各非同步動作共用的狀態機（同 `TimelineOperationState` 的角色）。
enum EULAOperationState: Equatable {
    case idle
    case submitting
    case failure(AppError)

    var isSubmitting: Bool { self == .submitting }
}

/// EULA 同意頁（LS-190，依 LS-152 稿）的 `@Observable` 狀態管理——把 `EULAAPIClient` 包成
/// `RootView.AuthenticatedGate` 能直接讀狀態驅動重繪的 store（同 `FamilyStore` 之於
/// `FamilyAPIClient` 的角色）。
@MainActor
@Observable
final class EULAStore {
    private let apiClient: EULAAPIClient

    private(set) var checkState: EULAOperationState = .idle
    private(set) var acceptState: EULAOperationState = .idle
    /// `checkStatus` 成功後記下的目前生效版本——`accept()` 呼叫 `accept_eula(p_version:)` 時
    /// 用它當參數。`nil`＝尚未檢查過。
    private(set) var currentVersion: String?
    /// `checkStatus` 的判定結果：`true`＝必須顯示同意頁；`nil`＝尚未檢查過或檢查中／失敗。
    private(set) var shouldPresent: Bool?
    /// LS-190 R2（merge-review R1 B2(b)）：`shouldPresent`／`currentVersion` 這組結果屬於哪個
    /// `userID`——同 `FamilyStore.ownerUserID` 的既有手法。呼叫端（`AuthenticatedGate.eulaGate`）
    /// 用 `isKnown(for:)` 確認這組結果屬於目前登入者，換帳號後（同機 A 登出、B 登入）這個值
    /// 還沒更新之前一律視為未知，不會誤放行成 A 殘留的 `shouldPresent == false`。
    private(set) var judgedUserID: UUID?

    init(apiClient: EULAAPIClient) {
        self.apiClient = apiClient
    }

    /// `RootView.AuthenticatedGate` 在 `.task(id: authStore.session?.userID)` 呼叫——併行讀
    /// 目前生效版本與呼叫者自己已同意的版本，交給 `EULAConsentPolicy` 判定。
    ///
    /// LS-190 R2 m1（merge-review R1）：`guard !checkState.isSubmitting` 同 `FamilyStore`／
    /// `ChildrenStore` 系列既有慣例，擋同一輪內的重複呼叫（例如 `FamilyLookupFailedView`
    /// 「重試」鈕被連點兩下）。
    ///
    /// LS-190 R2 B2(b)：換帳號（`userID != judgedUserID`）時**先**把 `shouldPresent`／
    /// `currentVersion` 清成 `nil`，再開始這次檢查——`isKnown(for:)` 在網路往返完成前會回
    /// `false`，呼叫端因此看到「未知，擋」而不是沿用上一位使用者的殘留判定。
    func checkStatus(userID: UUID) async {
        guard !checkState.isSubmitting else { return }
        if judgedUserID != userID {
            shouldPresent = nil
            currentVersion = nil
        }
        judgedUserID = userID
        checkState = .submitting
        do {
            async let currentTask = apiClient.fetchCurrentVersion()
            async let acceptedTask = apiClient.fetchAcceptedVersion(userID: userID)
            let (current, accepted) = try await (currentTask, acceptedTask)
            currentVersion = current
            shouldPresent = EULAConsentPolicy.shouldPresent(acceptedVersion: accepted, currentVersion: current)
            checkState = .idle
        } catch {
            checkState = .failure(AppError.map(error))
        }
    }

    /// `shouldPresent` 是否可信任用於 `userID` 這位目前登入者——`.submitting` 期間或
    /// `judgedUserID` 不符時一律不可信任（LS-190 R2 B2(b)）。呼叫端據此決定要不要放行到家庭
    /// 查詢，而不是只看 `shouldPresent == false`。
    func isKnown(for userID: UUID) -> Bool {
        judgedUserID == userID && !checkState.isSubmitting
    }

    /// 「我已閱讀並同意」——成功後直接把 `shouldPresent` 收回 `false`（不必重新
    /// `checkStatus`，避免多一次往返；同意紀錄本身已經由 `accept_eula()` 落地，見
    /// `docs/API.md` §4）。呼叫者是誰不需要另外傳入：`accept_eula()` 用伺服器端
    /// `auth.uid()`，這裡只操作 `checkStatus` 已經記下的 `currentVersion`／`judgedUserID`
    /// （LS-190 R2 informational-1：R1 版簽名多帶一個沒用到的 `userID` 參數，已移除）。
    ///
    /// LS-190 R2 m1：`guard !acceptState.isSubmitting` 同上，擋連點。
    ///
    /// **LS055（版本不符）自動重抓一次目前版本**（`docs/API.md` §4：「呼叫端多半是讀到的
    /// 版本已經過期，該重新抓一次目前版本、重新顯示條款」）——零容忍條款摘要本身是 app 內建
    /// 靜態文案（不隨版號變動，見 `EULAConsentView` 文件註解），重抓後仍停在同一頁，使用者
    /// 再次按下「同意並繼續」即可用新版號重試，不需要整頁重新載入。
    @discardableResult
    func accept() async -> Bool {
        guard !acceptState.isSubmitting, let version = currentVersion else { return false }
        acceptState = .submitting
        do {
            try await apiClient.acceptEULA(version: version)
            acceptState = .idle
            shouldPresent = false
            return true
        } catch {
            let mapped = AppError.map(error)
            if case .rejected(_, let code) = mapped, code == LSErrorCode.eulaVersionMismatch.rawValue,
               let refreshed = try? await apiClient.fetchCurrentVersion() {
                currentVersion = refreshed
            }
            acceptState = .failure(mapped)
            return false
        }
    }

    /// 使用者「不同意」登出，或本 store 需要在使用者換帳號時歸零——同
    /// `TimelineStore.reset()`／`ChildrenStore.reset()` 的角色。
    func reset() {
        checkState = .idle
        acceptState = .idle
        currentVersion = nil
        shouldPresent = nil
        judgedUserID = nil
    }

    #if DEBUG
    /// `TapTargetGateHarness`／`#Preview` 用：同步灌狀態，不經過 async `checkStatus`——同
    /// `TimelineStore.seedForPreview` 的角色與理由（見該檔）。整支 `#if DEBUG` 圍住，Release
    /// build 不會編到。
    ///
    /// `judgedUserID`（LS-190 R2）：`.eulaConsent`（單獨掛 `EULAConsentView`，不經過
    /// `AuthenticatedGate`）不會呼叫 `isKnown(for:)`，留 `nil` 沒差；
    /// `eulaConsentToTimelineHost` 直接建構 `AuthenticatedGate`，`eulaGate` 會呼叫
    /// `isKnown(for:)`，呼叫端必須傳跟 `authStore.seedSessionForPreview` 同一個 `userID`，
    /// 否則 harness 會卡在「正在確認條款狀態…」永遠進不去。
    @MainActor
    func seedForPreview(shouldPresent: Bool, currentVersion: String, judgedUserID: UUID? = nil) {
        self.shouldPresent = shouldPresent
        self.currentVersion = currentVersion
        self.judgedUserID = judgedUserID
        checkState = .idle
    }
    #endif
}

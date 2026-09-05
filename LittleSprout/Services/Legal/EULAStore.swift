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

    init(apiClient: EULAAPIClient) {
        self.apiClient = apiClient
    }

    /// `RootView.AuthenticatedGate` 在 `.task(id: authStore.session?.userID)` 呼叫——併行讀
    /// 目前生效版本與呼叫者自己已同意的版本，交給 `EULAConsentPolicy` 判定。
    func checkStatus(userID: UUID) async {
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

    /// 「我已閱讀並同意」——成功後直接把 `shouldPresent` 收回 `false`（不必重新
    /// `checkStatus`，避免多一次往返；同意紀錄本身已經由 `accept_eula()` 落地，見
    /// `docs/API.md` §4）。
    ///
    /// **LS055（版本不符）自動重抓一次目前版本**（`docs/API.md` §4：「呼叫端多半是讀到的
    /// 版本已經過期，該重新抓一次目前版本、重新顯示條款」）——零容忍條款摘要本身是 app 內建
    /// 靜態文案（不隨版號變動，見 `EULAConsentView` 文件註解），重抓後仍停在同一頁，使用者
    /// 再次按下「同意並繼續」即可用新版號重試，不需要整頁重新載入。
    @discardableResult
    func accept(userID: UUID) async -> Bool {
        guard let version = currentVersion else { return false }
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
    }

    #if DEBUG
    /// `TapTargetGateHarness`／`#Preview` 用：同步灌狀態，不經過 async `checkStatus`——同
    /// `TimelineStore.seedForPreview` 的角色與理由（見該檔）。整支 `#if DEBUG` 圍住，Release
    /// build 不會編到。
    @MainActor
    func seedForPreview(shouldPresent: Bool, currentVersion: String) {
        self.shouldPresent = shouldPresent
        self.currentVersion = currentVersion
        checkState = .idle
    }
    #endif
}

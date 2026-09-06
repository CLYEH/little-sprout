import Foundation
import Observation

/// LS-193 merge-review R2 B2：`delete_my_account()` RPC 成功、Edge Function 失敗（或 app 被殺掉）
/// 後的續傳呼叫（`finalizeAccountDeletion()`）**唯一擁有者**——R2 版把這個呼叫做成
/// `DeleteAccountFlowModel.init` 的副作用，但 SwiftUI 的 `NavigationLink { DeleteAccountFlowView
/// (...) }`／`navigationDestination` 兩種 destination 都是「每次 body 求值就重新建構」（只有
/// `body` 本身延遲），`initialValue:` 因此可能建出多個 throwaway model 實例，每個實例的
/// `Task { await performDeletion() }` 都會真的打一次 EF、彼此不去重——被丟棄的實例上的 Task
/// 不會被取消，畫面上使用者看到的那個實例可能已經進了 04h，背景那個 throwaway 實例卻悄悄把
/// 帳號刪完、把旗標清掉，兩邊狀態對不上。
///
/// 訂正後：這支物件是 app 存活期間唯一一份（`LittleSproutApp` 建一次、隨 `RootView` 往下傳，
/// 同 `accountAPIClient`／`FamilyStore` 等既有 app 層物件的角色），`resumeIfPending(userID:)`
/// 用 `inFlightUserIDs` 去重——不論從 `AuthenticatedGate`（登入完成／回前景）、
/// `DeleteAccountFlowView`（`.task` 進場）還是 `ForkView`（「重試刪除」按下）哪個入口呼叫，
/// 同一個 `userID` 同時只會有一個真正在飛的 `finalizeAccountDeletion()` 呼叫。
/// `DeleteAccountFlowModel.init` 因此不再做任何 I/O，只讀 `state` 決定要顯示什麼（見該檔）。
@MainActor
@Observable
final class PendingAccountDeletionResumer {
    enum State: Equatable {
        case idle
        case inProgress
        case completed
        case failed(AppError)
    }

    private let accountAPIClient: AccountAPIClient
    private(set) var state: State = .idle
    private var inFlightUserIDs: Set<UUID> = []

    init(accountAPIClient: AccountAPIClient) {
        self.accountAPIClient = accountAPIClient
    }

    /// 見型別文件註解——`PendingAccountDeletion.isPending(userID:)` 為 false（沒有旗標）或
    /// 這個 `userID` 已經有一個呼叫在飛時都是 no-op，可以放心從多個入口重複呼叫。
    ///
    /// 旗標不存在時把 `state` 收斂回 `.idle`：`state` 是這個單例橫跨整個 app 生命週期的欄位，
    /// 不會在使用者登出時自動歸零（`PendingAccountDeletion` 本身也刻意不因為登出而清旗標，見
    /// 該檔文件註解）——沒有這行，上一位使用者續傳完成（`.completed`）留下的殘留值可能會被
    /// 下一位登入者（或同一位使用者下一次全新流程）的 `DeleteAccountFlowModel.step` 誤讀。
    /// `AuthenticatedGate` 每次登入都會呼叫這支一次（見該檔），天然形成「每次登入自動收斂」。
    func resumeIfPending(userID: UUID) {
        guard PendingAccountDeletion.isPending(userID: userID) else {
            state = .idle
            return
        }
        guard !inFlightUserIDs.contains(userID) else { return }
        inFlightUserIDs.insert(userID)
        state = .inProgress
        Task {
            defer { inFlightUserIDs.remove(userID) }
            do {
                try await accountAPIClient.finalizeAccountDeletion()
                PendingAccountDeletion.clear(userID: userID)
                state = .completed
            } catch {
                state = .failed(AppError.map(error))
            }
        }
    }

    /// 04h「重試」在續傳情境下呼叫——語意上等同再叫一次 `resumeIfPending`，獨立命名只是讓
    /// `DeleteAccountFlowModel` 呼叫端讀起來對應「使用者主動重試」而非「系統自動偵測」。
    func retry(userID: UUID) {
        resumeIfPending(userID: userID)
    }

    #if DEBUG
    /// `#Preview`／`TapTargetGateHarness` 用：同步把 `state` 設成給定值，不需要真的走一次
    /// async `finalizeAccountDeletion()`（同 `FamilyStore.seedMyFamilyForPreview` 的既有作法）。
    func seedStateForPreview(_ state: State) {
        self.state = state
    }

    /// 同 `FamilyStore.preview()` 的角色——`PreviewAccountAPIClient` 兩支方法皆為 no-op。
    static func preview() -> PendingAccountDeletionResumer {
        PendingAccountDeletionResumer(accountAPIClient: PreviewAccountAPIClient())
    }
    #endif
}

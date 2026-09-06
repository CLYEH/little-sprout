import Foundation
import Observation

/// LS-193（LS-24 刪除帳號流程）：04e–04h 的狀態機，掛在 `DeleteAccountFlowView` 上（同
/// `OTPVerificationModel` 的既有角色分工——畫面級的獨立流程用專屬 `@Observable` model，不塞進
/// 隨 app 存活的共用 store）。04a／04b／04d 三分流不在這個 model 裡快取，見
/// `DeleteAccountClassification` 文件註解——`classification` 這裡即時讀 `familyStore` 現況。
///
/// **merge-review R2 B2 訂正**：R2 版在 `init` 裡看到 `PendingAccountDeletion` 旗標就直接
/// `Task { await performDeletion() }`——SwiftUI 的 `NavigationLink { DeleteAccountFlowView(...) }`
/// ／`navigationDestination` 兩種 destination 都是「每次 body 求值就重新建構」，`State
/// (initialValue:)` 的實參因此可能建出多個 throwaway model 實例，每個實例的 `Task` 都會真的打
/// 一次 `finalizeAccountDeletion()`、彼此不去重（被丟棄實例上的 Task 不會被取消）。訂正後
/// `init` 不做任何 I/O，續傳呼叫的唯一擁有者是 `PendingAccountDeletionResumer`（app 層單例，
/// 跨 model 實例／跨呼叫端用 `userID` 去重）；`step` 是純計算屬性，優先看使用者手動操作留下的
/// `manualStep`，其次看 `resumer.state`，最後（`resumer` 還沒被任何人叫過、但本機旗標已經
/// 存在）同步讀一次 `PendingAccountDeletion.isPending`（純讀 `UserDefaults`，不是網路 I/O）
/// 先顯示 04f 佔位，避免第一幀畫面閃到三分流——見 `step` 文件註解。
@MainActor
@Observable
final class DeleteAccountFlowModel {
    private let accountAPIClient: AccountAPIClient
    let familyStore: FamilyStore
    private let authStore: AuthStore
    private let childrenStore: ChildrenStore
    private let timelineStore: TimelineStore
    private let albumsStore: AlbumsStore
    /// LS-193：merge 進 LS-190（EULA 同意流程）之後補上——同 `SettingsView.signOut()`／
    /// `AuthenticatedGate.disagreeAndSignOut()` 既有理由，登出時必須歸零，不清掉會讓同機換
    /// 帳號的下一位使用者沿用上一位的 `shouldPresent`、繞過 EULA 閘門。
    private let eulaStore: EULAStore
    /// merge-review R2 B2：續傳（RPC 已成功、EF 還沒打完）的唯一擁有者，見型別文件註解。
    private let resumer: PendingAccountDeletionResumer

    /// 使用者手動操作（`proceedToFinalConfirm`／`confirmDeletion` 的一般流程）留下的 step——
    /// `nil` 代表這個 model 自己還沒往下走。續傳（`resumer` 驅動）的顯示狀態不寫進這裡，見
    /// `step` 計算屬性怎麼合併兩者。
    private var manualStep: DeleteAccountStep?
    /// `LS050` 的 `DETAIL`（伺服器現況）——`classification` 落在 `.mustTransferOwnership` 時
    /// 優先使用這份清單覆寫 client 端預判的清單（見該屬性文件註解）。`nil` 時 `classification`
    /// 純用 `FamilyStore.leaveFlowCase` 的 client 端預判。
    private(set) var serverPendingTransferFamilies: [FamilyPendingTransfer]?
    /// 一般流程（`performDeletion()`）自己的 in-flight 旗標——續傳流程走 `resumer`，不會設這個，
    /// 見 `isProcessing` 計算屬性怎麼合併兩者。
    private var manualIsProcessing = false
    /// 這次流程內 `delete_my_account()` 是否已經成功——04h「重試」用它決定要從頭呼叫 RPC，
    /// 還是只重打 Edge Function（RPC 已經成功、只是 `finalizeAccountDeletion()` 那一步失敗，
    /// 見 `performDeletion()`）。這個 model 只服務單一次刪除流程，畫面消失就整個丟棄，不需要
    /// 跨流程持久化——跨流程的續傳交給 `resumer`／`PendingAccountDeletion`。
    private(set) var deletionRequested = false
    private(set) var isFinishing = false

    init(
        accountAPIClient: AccountAPIClient,
        familyStore: FamilyStore,
        authStore: AuthStore,
        childrenStore: ChildrenStore,
        timelineStore: TimelineStore,
        albumsStore: AlbumsStore,
        eulaStore: EULAStore,
        resumer: PendingAccountDeletionResumer
    ) {
        self.accountAPIClient = accountAPIClient
        self.familyStore = familyStore
        self.authStore = authStore
        self.childrenStore = childrenStore
        self.timelineStore = timelineStore
        self.albumsStore = albumsStore
        self.eulaStore = eulaStore
        self.resumer = resumer
    }

    /// `nil`＝還在三分流（畫面讀 `classification` 決定顯示 04a／04b／04d）；非 nil＝已經往下走
    /// 到 04e／04f／04g／04h。
    ///
    /// 合併兩個來源：①`manualStep`（使用者在這個 model 實例上主動按過的結果）優先；
    /// ②沒有的話看 `resumer.state`（續傳中／已完成／已失敗）；③兩者都還沒有值、但本機續傳
    /// 旗標已經存在（`resumer` 這一輪還沒被任何人叫到——`DeleteAccountFlowView.task` 通常要等
    /// 下一輪 runloop 才觸發）→ 同步顯示 `.inProgress` 佔位，純讀 `UserDefaults`，不是網路
    /// I/O，避免第一幀畫面閃到三分流。
    var step: DeleteAccountStep? {
        if let manualStep { return manualStep }
        switch resumer.state {
        case .inProgress: return .inProgress
        case .completed: return .completed
        case .failed(let error): return .failed(error)
        case .idle:
            guard let userID = authStore.session?.userID else { return nil }
            return PendingAccountDeletion.isPending(userID: userID) ? .inProgress : nil
        }
    }

    /// 04a／04b／04d 三分流——即時讀 `familyStore` 現況，見 `DeleteAccountClassification`
    /// 文件註解。`serverPendingTransferFamilies` 有值時（LS050 過）優先覆寫 04b 顯示的清單。
    ///
    /// **merge-review R2 m2 訂正**：`myFamily == nil` 時（`ForkView`「刪除帳號」入口——多半是
    /// 停權使用者，`family_ids()` 等集合函式把他的家庭在 RLS 層收斂成 0 列，`LS052`／`LS054`）
    /// 原本短路成 `.generalMember`，讓 04a 對這位使用者說「其他家人跟他們的照片、日記完全不受
    /// 影響」——client 端這時完全看不到家庭全貌，這句話沒有依據可以講，若這位使用者其實是唯一
    /// 成員，`delete_my_account()` 會走 API.md §4 情況 2（整個家庭連同 albums／diaries／media
    /// cascade 硬刪），04a 卻講了一句安慰性的假話，跟 M1 的危害是同一種類型。訂正後改回
    /// `.soleMember`（沿用既有 04d `SoleMemberDeleteWarningView`，不新增設計板——稿面缺口記
    /// LS-208 範圍 8）：`familyName.isEmpty` 已有優雅降級（「這個家庭」而非假造名稱，見該檔
    /// `title`／`bodyText` 文件），警示文案框架本來就是「往最壞情況說」，即使這位使用者其實不是
    /// 唯一成員也只是多一句保守警告，不會像 04a 那樣講出一句可能誤導、鼓勵放心刪除的假安慰。
    var classification: DeleteAccountClassification {
        if let serverPendingTransferFamilies {
            return .mustTransferOwnership(families: serverPendingTransferFamilies)
        }
        guard familyStore.myFamily != nil else {
            return .soleMember
        }
        return classifyDeleteAccountFlow(
            membersState: familyStore.membersState,
            ownerUserID: familyStore.ownerUserID,
            members: familyStore.members,
            myFamily: familyStore.myFamily
        )
    }

    /// 一般流程（`performDeletion()`）的 in-flight 旗標，合併續傳流程（`resumer.state ==
    /// .inProgress`）——04h「重試」鈕的 `isLoading` 兩種來源都該轉圈。
    var isProcessing: Bool {
        manualIsProcessing || resumer.state == .inProgress
    }

    /// `DeleteAccountFlowView.task` 進場呼叫（不是 `init`，見型別文件註解 B2 訂正）：如果本機
    /// 續傳旗標存在，觸發（或確認已在飛的）續傳呼叫；旗標不存在時是 no-op（`resumer` 自己會把
    /// 殘留的 `.completed`／`.failed` 收斂回 `.idle`，見該型別文件註解）。
    func resumeIfNeeded() {
        guard let userID = authStore.session?.userID else { return }
        resumer.resumeIfPending(userID: userID)
    }

    /// 04a／04d「繼續刪除帳號」／「我了解，繼續刪除」按下——進 04e。`origin` 由呼叫端
    /// （`GeneralMemberDeleteAccountView`／`SoleMemberDeleteWarningView`）依自己是哪一張畫面
    /// 傳入，不用讀 `step`（04e 之前 `step` 恆為 `nil`，見型別文件註解）。
    func proceedToFinalConfirm(origin: DeleteAccountStep.FinalConfirmOrigin) {
        manualStep = .finalConfirm(origin: origin)
    }

    /// 04e「取消」——退回三分流（`step = nil`），畫面即時讀 `classification` 決定顯示 04a
    /// 或 04d，跟使用者離開時的那一張自然一致（沒有東西在這段期間改變過）。
    func cancelFinalConfirm() {
        guard case .finalConfirm = manualStep else { return }
        manualStep = nil
    }

    /// 04b「我已完成轉移，重新檢查」——直接重呼 `delete_my_account()`（LS-152 Notes IN-4：
    /// 使用者已經完成一次有意義的動作（離開設定頁去轉移），不需要再回到 04e 重打一次確認詞）。
    func recheckAfterTransfer() {
        Task { await performDeletion() }
    }

    /// 04e 輸入確認詞相符後呼叫（見 `DeleteAccountConfirmationPhrase`）；04h「重試」也呼叫
    /// 這支。**merge-review R2 B2**：這個 model 實例若是靠 `resumer` 續傳到 04f／04h（`manualStep`
    /// 從未被設過，`step` 顯示的是 `resumer.state` 的投影），04h「重試」該重呼的是
    /// `resumer.retry(userID:)`（RPC 早就成功了，不能再走 `performDeletion()` 那條會重打
    /// `deleteMyAccount()` 的路——這個 model 實例自己的 `deletionRequested` 對這種情境毫無意義，
    /// 一律是 `false`）；`manualStep` 非 nil 代表這是一般流程自己失敗，`performDeletion()`
    /// 既有的 `deletionRequested` 判斷才適用。
    func confirmDeletion() {
        if manualStep == nil, let userID = authStore.session?.userID, resumer.state != .idle {
            resumer.retry(userID: userID)
            return
        }
        Task { await performDeletion() }
    }

    private func performDeletion() async {
        guard !manualIsProcessing else { return }
        manualIsProcessing = true
        defer { manualIsProcessing = false }
        manualStep = .inProgress
        if !deletionRequested {
            do {
                switch try await accountAPIClient.deleteMyAccount() {
                case .success:
                    deletionRequested = true
                    serverPendingTransferFamilies = nil
                    // merge-review R1 M3：RPC 這一步已經不可逆——落地本機續傳旗標，app 這裡
                    // 之後如果被殺掉／EF 失敗，下次啟動由 `PendingAccountDeletionResumer`
                    // 接手續傳（見該型別／`PendingAccountDeletion` 文件註解）。
                    if let userID = authStore.session?.userID {
                        PendingAccountDeletion.markPending(userID: userID)
                    }
                case .mustTransferOwnership(let families):
                    serverPendingTransferFamilies = families
                    manualStep = nil // 退回三分流，`classification` 用上面剛存的伺服器清單顯示 04b。
                    return
                }
            } catch {
                manualStep = .failed(AppError.map(error))
                return
            }
        }
        // docs/API.md §4／§10：deleteMyAccount() 回傳成功後必須立即呼叫 Edge Function，中間
        // 不得允許使用者做任何操作——`step` 已經在上面轉成 `.inProgress`，這裡沒有任何 await
        // 前的分支會把控制權交還給使用者可互動的畫面。
        do {
            try await accountAPIClient.finalizeAccountDeletion()
            manualStep = .completed
            // 完成了，續傳旗標的任務結束——`auth.users` 這個 userID 的列已經被 EF 刪除，
            // UUID 不會重複使用，理論上用不到了，這裡清掉純粹是不留垃圾。
            if let userID = authStore.session?.userID {
                PendingAccountDeletion.clear(userID: userID)
            }
        } catch {
            manualStep = .failed(AppError.map(error))
        }
    }

    /// 04g「回到登入畫面」——清 stores＋登出（同 `SettingsView.signOut()`／
    /// `AuthenticatedGate.disagreeAndSignOut()` 既有清單，含 `EULAStore`）。
    func finishAndReturnToWelcome() async {
        guard !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }
        await authStore.forceSignOutLocally()
        familyStore.reset()
        childrenStore.reset()
        timelineStore.reset()
        albumsStore.reset()
        eulaStore.reset()
    }
}

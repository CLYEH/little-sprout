import Foundation
import Observation

/// LS-193（LS-24 刪除帳號流程）：04e–04h 的狀態機，掛在 `DeleteAccountFlowView` 上（同
/// `OTPVerificationModel` 的既有角色分工——畫面級的獨立流程用專屬 `@Observable` model，不塞進
/// 隨 app 存活的共用 store）。04a／04b／04d 三分流不在這個 model 裡快取，見
/// `DeleteAccountClassification` 文件註解——`classification` 這裡即時讀 `familyStore` 現況。
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

    /// `nil`＝還在三分流（畫面讀 `classification` 決定顯示 04a／04b／04d）；非 nil＝已經往下走
    /// 到 04e／04f／04g／04h。
    private(set) var step: DeleteAccountStep?
    /// `LS050` 的 `DETAIL`（伺服器現況）——`classification` 落在 `.mustTransferOwnership` 時
    /// 優先使用這份清單覆寫 client 端預判的清單（見該屬性文件註解）。`nil` 時 `classification`
    /// 純用 `FamilyStore.leaveFlowCase` 的 client 端預判。
    private(set) var serverPendingTransferFamilies: [FamilyPendingTransfer]?
    private(set) var isProcessing = false
    /// 這次流程內 `delete_my_account()` 是否已經成功——04h「重試」用它決定要從頭呼叫 RPC，
    /// 還是只重打 Edge Function（RPC 已經成功、只是 `finalizeAccountDeletion()` 那一步失敗，
    /// 見 `performDeletion()`）。這個 model 只服務單一次刪除流程，畫面消失就整個丟棄，不需要
    /// 跨流程持久化。
    private(set) var deletionRequested = false
    private(set) var isFinishing = false

    init(
        accountAPIClient: AccountAPIClient,
        familyStore: FamilyStore,
        authStore: AuthStore,
        childrenStore: ChildrenStore,
        timelineStore: TimelineStore,
        albumsStore: AlbumsStore,
        eulaStore: EULAStore
    ) {
        self.accountAPIClient = accountAPIClient
        self.familyStore = familyStore
        self.authStore = authStore
        self.childrenStore = childrenStore
        self.timelineStore = timelineStore
        self.albumsStore = albumsStore
        self.eulaStore = eulaStore
        // merge-review R1 M3：`delete_my_account()` RPC 上次已經成功、只是 Edge Function
        // 沒打完（app 被系統回收／使用者關掉，或這是續傳到 `AuthenticatedGate`／`ForkView`
        // 那條路徑，見 `PendingAccountDeletion` 文件註解）——這個 model 一建構就直接續傳，
        // 不讓使用者先看到三分流或 04e。`step = .inProgress` 這裡同步賦值（不是等
        // `performDeletion()` 裡那行非同步才設）：`Task { }` 排程到真的執行之間有極短的
        // 空窗，若不在這裡先設，空窗期間 `content` 會依 `step == nil` 短暫算一次
        // `classification`，畫面可能閃一格三分流才跳到 04f。
        if let userID = authStore.session?.userID, PendingAccountDeletion.isPending(userID: userID) {
            deletionRequested = true
            step = .inProgress
            Task { await performDeletion() }
        }
    }

    /// 04a／04b／04d 三分流——即時讀 `familyStore` 現況，見 `DeleteAccountClassification`
    /// 文件註解。`serverPendingTransferFamilies` 有值時（LS050 過）優先覆寫 04b 顯示的清單。
    ///
    /// **merge-review R1 M2**：`myFamily == nil` 時（`ForkView`「刪除帳號」入口——多半是停權
    /// 使用者，`family_ids()` 等集合函式把他的家庭在 RLS 層收斂成 0 列，`LS052`／`LS054`）
    /// 直接短路成 `.generalMember`，不呼叫 `classifyDeleteAccountFlow`：那支函式在
    /// `members`／`ownerUserID` 沒有機會載入時只會回 `.pending`，而這裡永遠沒有機會載入
    /// （`FamilyStore.refreshMembers()` 需要 `myFamily?.id` 才會真的打 API，見該方法），會卡死
    /// 在「還在載入」。`.generalMember` 是最誠實的簡化：client 端 RLS 本來就看不到這個帳號的
    /// 家庭全貌（唯一 owner／唯一成員這些細節對使用者不可見），`delete_my_account()` RPC 本身
    /// 對停權者有 LS-179 R2 的豁免、清理邏輯完全在伺服器端正確執行，跟 client 顯示哪張分流稿
    /// 無關；04a 畫面本身已經用 `familyName.isEmpty` 優雅降級成「你會離開這個家庭」（不假造
    /// 家庭名稱），見 `GeneralMemberDeleteAccountView.infoList` 文件註解。
    var classification: DeleteAccountClassification {
        if let serverPendingTransferFamilies {
            return .mustTransferOwnership(families: serverPendingTransferFamilies)
        }
        guard familyStore.myFamily != nil else {
            return .generalMember
        }
        return classifyDeleteAccountFlow(
            membersState: familyStore.membersState,
            ownerUserID: familyStore.ownerUserID,
            members: familyStore.members,
            myFamily: familyStore.myFamily
        )
    }

    /// 04a／04d「繼續刪除帳號」／「我了解，繼續刪除」按下——進 04e。`origin` 由呼叫端
    /// （`GeneralMemberDeleteAccountView`／`SoleMemberDeleteWarningView`）依自己是哪一張畫面
    /// 傳入，不用讀 `step`（04e 之前 `step` 恆為 `nil`，見型別文件註解）。
    func proceedToFinalConfirm(origin: DeleteAccountStep.FinalConfirmOrigin) {
        step = .finalConfirm(origin: origin)
    }

    /// 04e「取消」——退回三分流（`step = nil`），畫面即時讀 `classification` 決定顯示 04a
    /// 或 04d，跟使用者離開時的那一張自然一致（沒有東西在這段期間改變過）。
    func cancelFinalConfirm() {
        guard case .finalConfirm = step else { return }
        step = nil
    }

    /// 04b「我已完成轉移，重新檢查」——直接重呼 `delete_my_account()`（LS-152 Notes IN-4：
    /// 使用者已經完成一次有意義的動作（離開設定頁去轉移），不需要再回到 04e 重打一次確認詞）。
    func recheckAfterTransfer() {
        Task { await performDeletion() }
    }

    /// 04e 輸入確認詞相符後呼叫（見 `DeleteAccountConfirmationPhrase`）；04h「重試」也呼叫
    /// 這支——`deletionRequested` 讓它從中斷的那一步接續，不重打已經成功的呼叫。
    func confirmDeletion() {
        Task { await performDeletion() }
    }

    private func performDeletion() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        step = .inProgress
        if !deletionRequested {
            do {
                switch try await accountAPIClient.deleteMyAccount() {
                case .success:
                    deletionRequested = true
                    serverPendingTransferFamilies = nil
                    // merge-review R1 M3：RPC 這一步已經不可逆——落地本機續傳旗標，app 這裡
                    // 之後如果被殺掉／EF 失敗，下次啟動 `AuthenticatedGate` 才知道要直接續傳
                    // （見 `PendingAccountDeletion`／本 model `init` 的對應檢查）。
                    // merge-review R1 M3：RPC 這一步已經不可逆——落地本機續傳旗標，app 這裡
                    // 之後如果被殺掉／EF 失敗，下次啟動 `AuthenticatedGate` 才知道要直接續傳
                    // （見 `PendingAccountDeletion`／本 model `init` 的對應檢查）。
                    if let userID = authStore.session?.userID {
                        PendingAccountDeletion.markPending(userID: userID)
                    }
                case .mustTransferOwnership(let families):
                    serverPendingTransferFamilies = families
                    step = nil // 退回三分流，`classification` 用上面剛存的伺服器清單顯示 04b。
                    return
                }
            } catch {
                step = .failed(AppError.map(error))
                return
            }
        }
        // docs/API.md §4／§10：deleteMyAccount() 回傳成功後必須立即呼叫 Edge Function，中間
        // 不得允許使用者做任何操作——`step` 已經在上面轉成 `.inProgress`，這裡沒有任何 await
        // 前的分支會把控制權交還給使用者可互動的畫面。
        do {
            try await accountAPIClient.finalizeAccountDeletion()
            step = .completed
            // 完成了，續傳旗標的任務結束——`auth.users` 這個 userID 的列已經被 EF 刪除，
            // UUID 不會重複使用，理論上用不到了，這裡清掉純粹是不留垃圾。
            if let userID = authStore.session?.userID {
                PendingAccountDeletion.clear(userID: userID)
            }
        } catch {
            step = .failed(AppError.map(error))
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

/// `InviteFamilyView` 依 `FamilyStore` 狀態決定顯示哪一態——R2 N1：查詢中／查詢失敗必須跟
/// 「空」「已產生」清楚分開，不能讓使用者在「這個家庭到底有沒有邀請碼」還沒查到／查失敗時
/// 按到「產生邀請碼」（見 `FamilyStore.createInvite`／`refreshLatestInvite` 文件註解的三道
/// 防線——這裡是第 3 道：UI 層不顯示可按的產生鈕）。
///
/// 抽成獨立、可測試的純值型別，而不是把這段判斷散在 `InviteFamilyView.body` 裡：專案沒有
/// ViewInspector 依賴，View 層邏輯不可測，這裡集中成純函式才能單元測試釘住（同
/// `AuthButtonsState` 的理由，見該檔文件註解）。
enum InvitePhase: Equatable {
    /// 進場查詢現有邀請碼中——`lookupInviteState.isSubmitting`，且還沒有 `latestInvite`。
    case checkingExisting
    /// 進場查詢失敗，這個家庭到底有沒有邀請碼是未知狀態——不能讓使用者在這裡按「產生」。
    case lookupFailed(AppError)
    case empty
    case generating
    case generated(GeneratedInvite)

    /// 三個輸入涵蓋 `InviteFamilyView` 需要的所有 `FamilyStore` 狀態。優先序：使用者正在
    /// 建立／重新產生（`createInviteState.isSubmitting`）最優先；其次只要有 `latestInvite`
    /// 就顯示已產生（不管是查詢查到的還是剛建立的）；再來才看查詢自己的狀態；其餘（查詢成功
    /// 但沒有既有碼、或根本沒觸發過查詢）落回空狀態。
    init(
        lookupInviteState: FamilyOperationState,
        createInviteState: FamilyOperationState,
        latestInvite: GeneratedInvite?
    ) {
        if createInviteState.isSubmitting {
            self = .generating
        } else if let invite = latestInvite {
            self = .generated(invite)
        } else if lookupInviteState.isSubmitting {
            self = .checkingExisting
        } else if case .failure(let error) = lookupInviteState {
            self = .lookupFailed(error)
        } else {
            self = .empty
        }
    }

    /// 破壞性「重新產生」區只在已經有一支邀請碼可以撤銷時才有意義。
    var showsDestructiveSection: Bool {
        if case .generated = self { return true }
        if case .generating = self { return true }
        return false
    }
}

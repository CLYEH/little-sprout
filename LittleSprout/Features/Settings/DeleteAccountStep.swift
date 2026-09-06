import Foundation

/// LS-193（LS-24 刪除帳號流程，依 `design/littlesprout.pen` `LS-152` 04a–04h）：04e 之後的
/// 流程狀態機。04a／04b／04d 三分流刻意**不**存在這裡（見 `DeleteAccountClassification`
/// 文件註解）——`nil`（`DeleteAccountFlowModel.step`）代表「還在三分流，畫面即時讀
/// `FamilyStore` 現況決定顯示哪一張」。
enum DeleteAccountStep: Equatable {
    /// 04e：最終確認（輸入「刪除帳號」四個字）。
    case finalConfirm(origin: FinalConfirmOrigin)
    /// 04f：刪除進行中——不可返回、防重複送出。
    case inProgress
    /// 04g：完成——登出、回歡迎頁。
    case completed
    /// 04h：失敗——錯誤碼映射依 `AppError`，可重試。
    case failed(AppError)

    /// 04e 的「取消」該退回哪一張警告畫面——04e 只會從 04a／04d 這兩張進入（04b 沒有「繼續
    /// 刪除」按鈕，見 LS-152 Notes「04c 省略」／「IN-4」段：04b 的「重新檢查」直接重呼
    /// `delete_my_account()`，不經過 04e）。
    enum FinalConfirmOrigin: Equatable {
        case generalMember
        case soleMember
    }

    /// 04f／04g／04h 無 Nav Back——`docs/API.md`「中間不得允許使用者做任何操作」的硬性規定，
    /// 見 LS-152 Notes 畫面級屬性清單「04f/04g/04h」段；04e（連同三分流）維持系統預設導覽列。
    var showsNavigationBar: Bool {
        switch self {
        case .inProgress, .completed, .failed: false
        case .finalConfirm: true
        }
    }
}

/// 04a／04b／04d 三分流純函式——重用 `LeaveFlowCase`（LS-192，
/// `FamilyMemberActionVisibility.swift` 的 `resolveLeaveFlowCase`「本人角色＋家庭成員數」
/// 判斷）的判斷本體，不再另外寫一套判定（票文明訂）：`.leave` → 04a；`.mustTransferFirst` →
/// 04b；`.soleMember` → 04d。
///
/// **刻意不快取成 `DeleteAccountFlowModel` 的 stored property**（同 `FamilyMembersView
/// .startLeaveFlow()` 讀 `familyStore.leaveFlowCase` 的既有慣例，R1 覆盤後改用這個形狀）：
/// 快取版本需要額外的「進場重新整理」機制才能反映背景查詢（`SettingsView` 的補查、或使用者從
/// 04b「前往轉移」跳去 `FamilyMembersView` 完成轉移再返回）造成的資料變動，這裡改成每次都從
/// `FamilyStore` 現況即時算，`familyStore` 本身是 `@Observable`，資料一變 SwiftUI 自然重繪，
/// 不需要任何手動「重新分流」呼叫或時序窗口處理。
///
/// **merge-review R1 M1 訂正**：R1 版直接讀 `FamilyStore.leaveFlowCase`（`members` 為空時回
/// `.leave`），把「還不知道」跟「確定是一般成員」混成同一個結果——唯一成員在 `members` 還沒
/// 載回（或載入失敗）時會被誤判成 04a，一旦按下「繼續刪除帳號」，`DeleteAccountFlowView
/// .content` 只看 `step` 不再看 `classification`（04d 警告從此不可能再出現），04e 送出後
/// `delete_my_account()` 照樣把整個家庭連同其他成員的照片／日記永久刪除——**沒有伺服器兜底**
/// （04b 誤判有 `LS050` 兜底，04d 沒有）。訂正後不再共用 `leaveFlowCase` 這個「對空 members
/// 預設 `.leave`」的計算屬性，改直接吃 `membersState`／`ownerUserID`／`members` 三個原始輸入，
/// 讓「還在載入」「載入失敗」變成顯式、跟 `.generalMember` 互斥的分支；`resolveLeaveFlowCase`
/// 純判斷函式本體不變、簽名不變，`FamilyMembersView.startLeaveFlow()`（退出家庭流程）沿用的
/// `leaveFlowCase` 計算屬性也完全不受影響。
enum DeleteAccountClassification: Equatable {
    /// `members` 尚未載回（`membersState` 是 `.idle`／`.submitting`）——三分流還不知道答案，
    /// 絕不能代打成 `.generalMember`。
    case pending
    /// 上一次查 `members` 失敗（`membersState == .failure`）——同樣不能代打，顯示可重試錯誤。
    case membersLoadFailed(AppError)
    case generalMember
    case mustTransferOwnership(families: [FamilyPendingTransfer])
    case soleMember
}

/// - Parameters:
///   - membersState：`FamilyStore.membersState`——`.failure` 時優先於其他輸入判定。
///   - ownerUserID：`FamilyStore.ownerUserID`（實為「目前登入者的 user id」，見該屬性命名
///     沿革；不是「家庭 owner 的 id」）；`nil` 或在 `members` 裡找不到自己都視為「還沒載完」。
///   - members：`FamilyStore.members`。
///   - myFamily：呼叫端保證非 nil 才會走到這支（見 `DeleteAccountFlowModel.classification`
///     的 `myFamily == nil` 早退分支，M2）；這裡仍收 optional 是為了跟 `mustTransferFirst`
///     分支的既有防禦寫法對稱，不代表這支函式自己會遇到 nil。
func classifyDeleteAccountFlow(
    membersState: FamilyOperationState,
    ownerUserID: UUID?,
    members: [FamilyMember],
    myFamily: Family?
) -> DeleteAccountClassification {
    if case .failure(let error) = membersState {
        return .membersLoadFailed(error)
    }
    guard let ownerUserID, let myself = members.first(where: { $0.userID == ownerUserID }) else {
        return .pending
    }
    let others = members.filter { $0.userID != ownerUserID }
    switch resolveLeaveFlowCase(
        isOwner: myself.role == .owner,
        otherMembersCount: others.count,
        hasOtherOwner: others.contains { $0.role == .owner }
    ) {
    case .leave:
        return .generalMember
    case .mustTransferFirst:
        guard let myFamily else {
            // 防禦性 fallback，理論上不會發生：`myself` 都找得到了代表 `members`／
            // `ownerUserID` 已經載完，`myFamily` 沒有理由還是 nil（`M2` 的早退分支已經擋在
            // 這之前）。退回「還在載入」比代打 `.generalMember` 安全——不會有 04d 警告消失
            // 的風險，最多使用者多等一輪重繪。
            return .pending
        }
        return .mustTransferOwnership(
            families: [FamilyPendingTransfer(familyID: myFamily.id, familyName: myFamily.name)]
        )
    case .soleMember:
        return .soleMember
    }
}

/// 04e 最終確認輸入框的比對——獨立成純函式方便 XCTest 直接覆蓋，不需要透過渲染 SwiftUI
/// 視圖間接推論（同 `FamilyMemberActionVisibility.swift` 的既有慣例）。LS-152 Notes「十條-8」
/// 段：輸入框提示「輸入『刪除帳號』」，四個字全字比對；只去除頭尾空白（使用者可能不小心
/// 多打一個空格），不做其他正規化。
enum DeleteAccountConfirmationPhrase {
    static let expected = "刪除帳號"

    static func matches(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }
}

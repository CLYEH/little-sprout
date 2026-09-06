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
/// 判斷），不再另外寫一套判定（票文明訂）：`.leave` → 04a；`.mustTransferFirst` → 04b；
/// `.soleMember` → 04d。
///
/// **刻意不快取成 `DeleteAccountFlowModel` 的 stored property**（同 `FamilyMembersView
/// .startLeaveFlow()` 讀 `familyStore.leaveFlowCase` 的既有慣例，R1 覆盤後改用這個形狀）：
/// 快取版本需要額外的「進場重新整理」機制才能反映背景查詢（`SettingsView` 的補查、或使用者從
/// 04b「前往轉移」跳去 `FamilyMembersView` 完成轉移再返回）造成的資料變動，這裡改成每次都從
/// `FamilyStore` 現況即時算，`familyStore` 本身是 `@Observable`，資料一變 SwiftUI 自然重繪，
/// 不需要任何手動「重新分流」呼叫或時序窗口處理。
enum DeleteAccountClassification: Equatable {
    case generalMember
    case mustTransferOwnership(families: [FamilyPendingTransfer])
    case soleMember
}

func classifyDeleteAccountFlow(for leaveFlowCase: LeaveFlowCase, myFamily: Family?) -> DeleteAccountClassification {
    switch leaveFlowCase {
    case .leave:
        return .generalMember
    case .mustTransferFirst:
        guard let myFamily else {
            // 防禦性 fallback，理論上不會發生——能看到「刪除帳號」入口代表已經在家庭裡
            // （見 `RootView`／`SettingsView` 文件註解），沒有家庭資料就沒有東西可以列在
            // 04b。退回 04a 讓使用者至少能往下走，伺服器端 `delete_my_account()` 仍是
            // 最終裁決（撞到 LS050 會由 `DeleteAccountFlowModel` 導回 04b）。
            return .generalMember
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

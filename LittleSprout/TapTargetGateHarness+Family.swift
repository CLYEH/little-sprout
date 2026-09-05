#if DEBUG
import SwiftUI

/// LS-192：02／03 兩支新畫面的 harness host——拆成獨立檔案，理由同 `TapTargetGateHarness.swift`
/// 檔頭「merge LS-167」註解（主檔逼近 SwiftLint `file_length`／`type_body_length` 上限）。
/// `hostView(for:)` 的 switch 本體（主檔）呼叫這裡的 `static var`，因此不能是 `private`——
/// Swift 的 `private` 存取層級只到「同檔案」，退而求其次用預設的 internal（同
/// `FamilyStore.apiClient` 的既有取捨）。
extension TapTargetGateHarness {
    /// LS-192：初始態（未載入完成前）已有代表性——頭像沖印卡（`PhotosPicker` 觸發鈕）／
    /// 顯示名稱欄／儲存變更鈕／取消鈕四顆可點元件一開畫面就存在，不依賴 `.task` 非同步查詢
    /// `myProfile` 是否完成，同 `createChildHost` 的既有理由。
    @MainActor
    @ViewBuilder
    static var profileEditHost: some View {
        NavigationStack {
            ProfileEditView(
                familyStore: .preview(withFamily: Family(
                    id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
                )),
                familyID: UUID()
            )
        }
    }

    /// R2（merge-review R1 M8）：`seedOwnerUserIDForPreview` 用
    /// `PreviewFamilySamples.selfUserID`——這個固定值也是 `PreviewFamilyAPIClient.listMembers`
    /// 預設回傳樣本的「自己」`userID`（見該檔文件註解），兩邊對上之後 `myRole` 才能解析成
    /// `.owner`，每一列成員的動作選單（轉移家庭管理者／移出成員）才會渲染，是這個畫面唯一
    /// 需要 seed 才有代表性的互動元件（同 `.albumsPopulatedState` 需要 seed 假相簿才能量到
    /// 卡片的既有理由）；「退出家庭」鈕不受 seed 影響，任何狀態都會渲染。額外同步呼叫
    /// `seedMembersForPreview` 佈置跟 `listMembers` 預設樣本同樣形狀（僅 `userID` 不同）的
    /// 內容，避免量測發生在 `.task` 的 async `refreshMembers()` 完成之前的短暫空清單窗口
    /// （同 `.albumsPopulatedState` 用同步 seed 避開 async 時序窗口的既有慣例）；`.task`
    /// 完成後兩者內容等價，不影響量測結果。
    @MainActor
    @ViewBuilder
    static var familyMembersHost: some View {
        let store = FamilyStore.preview(withFamily: Family(
            id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
        ))
        store.seedOwnerUserIDForPreview(PreviewFamilySamples.selfUserID)
        store.seedMembersForPreview([
            FamilyMember(
                userID: PreviewFamilySamples.selfUserID, role: .owner, displayName: "陳美玲", avatarURL: nil
            ),
            FamilyMember(userID: UUID(), role: .member, displayName: "陳阿公", avatarURL: nil)
        ])
        return NavigationStack {
            FamilyMembersView(
                familyStore: store, childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview()
            )
        }
    }
}
#endif

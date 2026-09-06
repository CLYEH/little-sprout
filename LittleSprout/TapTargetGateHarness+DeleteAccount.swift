#if DEBUG
import SwiftUI

/// LS-193：刪除帳號流程（04a／04b／04d／04e／04g／04h）harness host，從
/// `TapTargetGateHarness.swift` 拆出獨立檔案——同 `TapTargetGateHarness+Legal.swift`／
/// `+UploadQueue.swift` 的既有先例（那支檔案疊上新 case 後會超過 SwiftLint `file_length`
/// 上限）。04f 進行中沒有任何互動元件（純顯示＋`ProgressView`），不需要量測，因此沒有對應的
/// tap-target UITest（同 `DiaryDetailView` 一類純顯示畫面的既有慣例）——`hostView(for:)` 分派
/// 與 `TapTargetGateScreenName` 註冊仍然都有（截圖對稿／registry-check 用），見下方
/// `deleteAccountInProgressHost` 文件註解。
///
/// 三分流（04a／04b／04d）各自需要不同的 `FamilyStore` 種子資料（見 `DeleteAccountStep
/// .initialDeleteAccountStep(for:myFamily:)` 文件註解），透過 `seedOwnerUserIDForPreview`／
/// `seedMembersForPreview` 同步佈置，不走 async fetch，沒有時序窗口（同
/// `familyMembersHost` 的既有作法）。種子邏輯抽到獨立函式（不是塞進 `@ViewBuilder` var 本體）
/// ——`@ViewBuilder` body 不能塞裸的 void 陳述式（同 `sectionTabViewWithDiaryHost` 的
/// `seededTimelineStore()` 既有作法，見該檔文件註解）。04e／04g／04h 三態不是
/// `DeleteAccountFlowView` 建構時天然會落到的初始態（那支只會落在 04a／04b／04d 之一），直接
/// 掛對應的子畫面（`FinalDeleteConfirmView`／`DeletionCompletedView`／`DeletionFailedView`），
/// 同 `MustTransferOwnershipFirstView` 這類「不是 SettingsView 直接子視圖也能被 harness 直接
/// 掛」的既有先例。
extension TapTargetGateHarness {
    @MainActor
    private static func makeFamily() -> Family {
        Family(id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true)
    }

    /// merge-review R3 n1 訂正：`performDeletion()` 改呼叫 `resumer.finalize(userID:)`，需要
    /// `authStore.session != nil` 才能真的走到 EF 那一步（見該方法 `guard let userID =
    /// authStore.session?.userID`）——`.preview()` 預設沒有 session（同
    /// `PreviewAuthService.currentSession` 預設 nil），這裡的 `userID` 跟各分流 `FamilyStore`
    /// 種子的 `ownerUserID` 是否同一個值不影響這支測試的目的（只是要有非 nil session），刻意
    /// 各自獨立、不共用同一個變數，避免耦合出跟本票無關的假設。
    @MainActor
    private static func sessionedAuthStore() -> AuthStore {
        let authStore = AuthStore.preview()
        authStore.seedSessionForPreview(
            AuthSession(userID: UUID(), email: "delete-account-harness@example.com", expiresAt: .distantFuture)
        )
        return authStore
    }

    @MainActor
    private static func generalMemberFamilyStore() -> FamilyStore {
        let familyStore = FamilyStore.preview(withFamily: makeFamily())
        let myID = UUID()
        familyStore.seedOwnerUserIDForPreview(myID)
        familyStore.seedMembersForPreview([
            FamilyMember(userID: myID, role: .member, displayName: "測試成員", avatarURL: nil),
            FamilyMember(userID: UUID(), role: .owner, displayName: "陳美玲", avatarURL: nil)
        ])
        return familyStore
    }

    @MainActor
    private static func mustTransferFamilyStore() -> FamilyStore {
        let familyStore = FamilyStore.preview(withFamily: makeFamily())
        let myID = UUID()
        familyStore.seedOwnerUserIDForPreview(myID)
        familyStore.seedMembersForPreview([
            FamilyMember(userID: myID, role: .owner, displayName: "測試成員", avatarURL: nil),
            FamilyMember(userID: UUID(), role: .member, displayName: "陳阿公", avatarURL: nil)
        ])
        return familyStore
    }

    @MainActor
    private static func soleMemberFamilyStore() -> FamilyStore {
        let familyStore = FamilyStore.preview(withFamily: makeFamily())
        let myID = UUID()
        familyStore.seedOwnerUserIDForPreview(myID)
        familyStore.seedMembersForPreview([
            FamilyMember(userID: myID, role: .owner, displayName: "測試成員", avatarURL: nil)
        ])
        return familyStore
    }

    @MainActor
    private static func makeModel(familyStore: FamilyStore) -> DeleteAccountFlowModel {
        DeleteAccountFlowModel(
            accountAPIClient: PreviewAccountAPIClient(), familyStore: familyStore, authStore: sessionedAuthStore(),
            childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview(),
            eulaStore: .preview(shouldPresent: false), resumer: .preview()
        )
    }

    @MainActor
    @ViewBuilder
    static var deleteAccountGeneralMemberHost: some View {
        let familyStore = generalMemberFamilyStore()
        NavigationStack {
            DeleteAccountFlowView(
                accountAPIClient: PreviewAccountAPIClient(), authStore: sessionedAuthStore(), familyStore: familyStore,
                childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview(),
                eulaStore: .preview(shouldPresent: false), resumer: .preview()
            )
        }
    }

    @MainActor
    @ViewBuilder
    static var deleteAccountMustTransferHost: some View {
        let familyStore = mustTransferFamilyStore()
        NavigationStack {
            DeleteAccountFlowView(
                accountAPIClient: PreviewAccountAPIClient(), authStore: sessionedAuthStore(), familyStore: familyStore,
                childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview(),
                eulaStore: .preview(shouldPresent: false), resumer: .preview()
            )
        }
    }

    @MainActor
    @ViewBuilder
    static var deleteAccountSoleMemberHost: some View {
        let familyStore = soleMemberFamilyStore()
        NavigationStack {
            DeleteAccountFlowView(
                accountAPIClient: PreviewAccountAPIClient(), authStore: sessionedAuthStore(), familyStore: familyStore,
                childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview(),
                eulaStore: .preview(shouldPresent: false), resumer: .preview()
            )
        }
    }

    /// 04f 進行中。**merge-review R1 i2 訂正**：這裡跟 `TapTargetGateScreenName
    /// .deleteAccountInProgress`／`TapTargetGateHarness.hostView(for:)` 的
    /// `.deleteAccountInProgress` case 都確實有掛（截圖對稿與 registry-check 都需要），舊註解說
    /// 「不進註冊表」「不掛 `hostView(for:)` 分派」是錯的。**merge-review R3 n2／R4 訂正**：
    /// 這裡不再是「無互動元件」——`DeletionInProgressView` 加了「登出」文字鈕（見該檔文件
    /// 註解），但仍然沒有寫對應的 tap-target UITest（沒有明確指示要求、且既有 04h「登出」
    /// UITest 已經覆蓋同一顆共用元件 `DeleteAccountTextButton` 的 `minHeight: 48`），這裡只
    /// 提供 host 給截圖對稿與 registry-check 用。
    @MainActor
    @ViewBuilder
    static var deleteAccountInProgressHost: some View {
        let model = makeModel(familyStore: .preview(withFamily: makeFamily()))
        NavigationStack {
            DeletionInProgressView(model: model)
        }
    }

    @MainActor
    @ViewBuilder
    static var deleteAccountFinalConfirmHost: some View {
        let model = makeModel(familyStore: .preview(withFamily: makeFamily()))
        NavigationStack {
            FinalDeleteConfirmView(model: model)
        }
    }

    @MainActor
    @ViewBuilder
    static var deleteAccountCompletedHost: some View {
        let model = makeModel(familyStore: .preview(withFamily: makeFamily()))
        NavigationStack {
            DeletionCompletedView(model: model)
        }
    }

    @MainActor
    @ViewBuilder
    static var deleteAccountFailedHost: some View {
        let model = makeModel(familyStore: .preview(withFamily: makeFamily()))
        NavigationStack {
            DeletionFailedView(model: model)
        }
    }
}
#endif

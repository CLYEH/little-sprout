#if DEBUG
import SwiftUI

/// LS-193：刪除帳號流程（04a／04b／04d／04e／04g／04h）harness host，從
/// `TapTargetGateHarness.swift` 拆出獨立檔案——同 `TapTargetGateHarness+Legal.swift`／
/// `+UploadQueue.swift` 的既有先例（那支檔案疊上新 case 後會超過 SwiftLint `file_length`
/// 上限）。04f 進行中沒有任何互動元件（純顯示＋`ProgressView`），不需要量測，因此不掛
/// case（同 `DiaryDetailView` 一類純顯示畫面的既有慣例）。
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
            accountAPIClient: PreviewAccountAPIClient(), familyStore: familyStore, authStore: .preview(),
            childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview()
        )
    }

    @MainActor
    @ViewBuilder
    static var deleteAccountGeneralMemberHost: some View {
        let familyStore = generalMemberFamilyStore()
        NavigationStack {
            DeleteAccountFlowView(
                accountAPIClient: PreviewAccountAPIClient(), authStore: .preview(), familyStore: familyStore,
                childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview()
            )
        }
    }

    @MainActor
    @ViewBuilder
    static var deleteAccountMustTransferHost: some View {
        let familyStore = mustTransferFamilyStore()
        NavigationStack {
            DeleteAccountFlowView(
                accountAPIClient: PreviewAccountAPIClient(), authStore: .preview(), familyStore: familyStore,
                childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview()
            )
        }
    }

    @MainActor
    @ViewBuilder
    static var deleteAccountSoleMemberHost: some View {
        let familyStore = soleMemberFamilyStore()
        NavigationStack {
            DeleteAccountFlowView(
                accountAPIClient: PreviewAccountAPIClient(), authStore: .preview(), familyStore: familyStore,
                childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview()
            )
        }
    }

    /// 04f 進行中——純顯示（`ProgressView`＋文字，無互動元件），不進 `TapTargetGateScreenName`
    /// 註冊表（同 `DayDividerView` 一類純顯示畫面的既有慣例：`TapTargetMeasurement.violations`
    /// 要求至少 1 個 Button／tappable 元件才不算「0 個元件＝0 個違規」的假陽性，這張板本來就
    /// 沒有）——這裡只提供給截圖對稿用，不掛 `hostView(for:)` 分派。
    @MainActor
    @ViewBuilder
    static var deleteAccountInProgressHost: some View {
        NavigationStack {
            DeletionInProgressView()
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

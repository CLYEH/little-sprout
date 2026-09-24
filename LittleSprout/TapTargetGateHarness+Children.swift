#if DEBUG
import SwiftUI

/// LS-312：`ChildrenManagementView` populated——原本在 `tap-target-exemptions.txt` 具名排除
/// （理由「需要 ChildrenStore preview 帶多筆假資料才有代表性」），寶貝列 row 目的地從 `edit`
/// 改推 `detail`（`ChildGrowthDetailView`）之後補上這支 host，順便也是「列 → 詳情 → 編輯」
/// 這條新導覽路徑唯一的機械複驗管道（QADriver 的 `runChildAvatar` 需要真的 Supabase 後端，
/// 不在 push gate／CI 覆蓋範圍）。
extension TapTargetGateHarness {
    @MainActor
    @ViewBuilder
    static var childrenManagementPopulatedHost: some View {
        let childrenStore = ChildrenStore.preview()
        childrenStore.seedRoleForPreview(.owner)
        childrenStore.seedForPreview(children: [
            Child(
                id: UUID(), name: "陳小安", birthday: BirthdayFormat.date(fromWireString: "2025-04-20")!,
                avatarURL: nil, deletedAt: nil, createdAt: Date()
            )
        ])
        return NavigationStack {
            ChildrenManagementView(
                familyStore: .preview(), childrenStore: childrenStore, growthAPIClient: PreviewGrowthAPIClient()
            )
        }
        .environment(\.horizontalSizeClass, .compact)
    }

    /// LS-370：同 `sectionSplitViewHost`（生產路徑 `AuthenticatedRootView` → `SectionSplitView`，強制
    /// regular），但 seed 兩個寶貝（對應稿面 `JbTfv` 左欄兩列），讓 `ChildrenManagementViewIPadTests`
    /// 能點左欄寶貝列、驗右欄詳情；時間軸／相簿維持空狀態，不影響其他分頁。
    @MainActor
    @ViewBuilder
    static var sectionSplitViewWithChildrenHost: some View {
        // 家庭有 seed，`ChildrenManagementView` 的 `.task` 會觸發 `refresh(familyID:)`——寶貝清單要從
        // preview client 回傳（`preview(children:)`），只 `seedForPreview` 會被 refresh 蓋成空清單。
        let childrenStore = ChildrenStore.preview(children: [
            Child(
                id: UUID(), name: "陳小安", birthday: BirthdayFormat.date(fromWireString: "2025-04-20")!,
                avatarURL: nil, deletedAt: nil, createdAt: Date()
            ),
            Child(
                id: UUID(), name: "陳小樂", birthday: BirthdayFormat.date(fromWireString: "2026-03-02")!,
                avatarURL: nil, deletedAt: nil, createdAt: Date()
            )
        ])
        AuthenticatedRootView(
            authStore: .preview(),
            familyStore: .preview(withFamily: Family(
                id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
            )),
            childrenStore: childrenStore, timelineStore: .preview(), albumsStore: .preview(),
            eulaStore: .preview(shouldPresent: false),
            diaryAPIClient: PreviewDiaryAPIClient(), growthAPIClient: PreviewGrowthAPIClient(),
            mediaUploadService: PreviewMediaUploadService(),
            accountAPIClient: PreviewAccountAPIClient(), resumer: .preview(),
            safetyAPIClient: PreviewSafetyAPIClient(), commentAPIClient: PreviewCommentAPIClient(),
            pushNotificationStore: .preview()
        )
        .environment(\.horizontalSizeClass, .regular)
    }
}
#endif

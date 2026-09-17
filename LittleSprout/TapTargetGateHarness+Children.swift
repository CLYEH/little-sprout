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
}
#endif

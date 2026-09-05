#if DEBUG
import SwiftUI

/// LS-188：`SettingsView` 的兩個角色／尺寸變體 host，從 `TapTargetGateHarness.swift` 拆出獨立
/// 檔案——加完這兩支之後那支檔案超過 SwiftLint `file_length` 上限，理由同
/// `TapTargetGateHarness+Albums.swift` 從主檔拆分的既有先例（見該檔文件註解）。不標 `private`
/// （跨檔案 extension 存取不到），改用預設（internal）存取層級。
extension TapTargetGateHarness {
    /// LS-188：同 `settingsHost`，但把角色釘死在 `.member`（`ChildrenStore
    /// .seedRoleForPreview`）——`TapTargetGateScreenName.settingsMemberRole` 文件註解。
    @MainActor
    @ViewBuilder
    static var settingsMemberRoleHost: some View {
        let childrenStore = ChildrenStore.preview()
        childrenStore.seedRoleForPreview(.member)
        return NavigationStack {
            SettingsView(
                authStore: .preview(),
                familyStore: .preview(withFamily: Family(
                    id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
                )),
                childrenStore: childrenStore,
                timelineStore: .preview(),
                albumsStore: .preview()
            )
        }
    }

    /// merge-review R1 B1：iPad（regular 寬度）互動回歸——`.environment(\.horizontalSizeClass,
    /// .regular)` 強制走 `SettingsView.regularBody`，同 `sectionTabViewHost` 用同一招強制走
    /// compact 的既有寫法。帶家庭狀態（含「邀請家人」列的既有回歸樣本）。
    @MainActor
    @ViewBuilder
    static var settingsRegularHost: some View {
        NavigationStack {
            SettingsView(
                authStore: .preview(),
                familyStore: .preview(withFamily: Family(
                    id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
                )),
                childrenStore: .preview(),
                timelineStore: .preview(),
                albumsStore: .preview()
            )
        }
        .environment(\.horizontalSizeClass, .regular)
    }
}
#endif

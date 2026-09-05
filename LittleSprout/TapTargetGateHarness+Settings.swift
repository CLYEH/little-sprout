#if DEBUG
import SwiftUI

/// LS-188：`SettingsView` 的兩個角色／尺寸變體 host，從 `TapTargetGateHarness.swift` 拆出獨立
/// 檔案——加完這兩支之後那支檔案超過 SwiftLint `file_length` 上限，理由同
/// `TapTargetGateHarness+Albums.swift` 從主檔拆分的既有先例（見該檔文件註解）。不標 `private`
/// （跨檔案 extension 存取不到），改用預設（internal）存取層級。
extension TapTargetGateHarness {
    /// merge LS-165／LS-167／LS-188：`hostView(for:)` switch 本體疊了多張票的新 case 後反覆
    /// 超過 SwiftLint `function_body_length` 上限，抽出這個既有 case 的內容還給界限內，行為
    /// 完全不變（同其餘 `*Host` computed var 的既有作法）。merge-review R1 M1(b)：「邀請家人」
    /// 列只在 `familyStore.myFamily != nil` 才渲染（LS-107）——`.preview(withFamily:)` 同步
    /// 餵一個家庭狀態，那顆列才會被量到（見 `FamilyStore.seedMyFamilyForPreview`／
    /// `PreviewFamilyAPIClient.swift`）。
    ///
    /// merge-review R2 informational 5：`.environment(\.horizontalSizeClass, .compact)`——
    /// 這個 host 原本沒有強制 size class，在 iPad 機型的模擬器上跑 `TapTargetGateTests
    /// .testSettingsView` 會因為預設 `horizontalSizeClass == .regular` 而渲染
    /// `SettingsView.regularBody`（sentinel「登出」只在 compact 版面或切到「帳號」後的
    /// regular 版面才看得到，預設選取是「個人」）導致測試紅。CI 固定跑 iPhone 不受影響，但
    /// 本機在 iPad 模擬器上重跑這條 gate 會誤判。同 `sectionTabViewHost`／
    /// `settingsRegularHost` 既有的既有作法，明確釘死 size class，不依賴執行裝置的實際
    /// idiom——這個 host 本來就是測 compact 版面，理應固定。
    @MainActor
    @ViewBuilder
    static var settingsHost: some View {
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
        .environment(\.horizontalSizeClass, .compact)
    }

    /// LS-188：同 `settingsHost`，但把角色釘死在 `.member`（`ChildrenStore
    /// .seedRoleForPreview`）——`TapTargetGateScreenName.settingsMemberRole` 文件註解。
    /// merge-review R2 informational 5：同 `settingsHost` 同一個理由，釘死 compact，不依賴
    /// 執行裝置的實際 idiom。
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
        .environment(\.horizontalSizeClass, .compact)
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

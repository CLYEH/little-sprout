import SwiftUI

/// LS-312：寶貝詳情（`ChildGrowthDetailView`）的承接方法，從 `ChildrenManagementView.swift`
/// 拆出獨立檔案——加完之後那支檔案超過 SwiftLint `type_body_length` 上限，同
/// `AlbumDetailView+Actions.swift` 從 `AlbumDetailView.swift` 拆分的既有先例（該檔文件註解）。
///
/// 不標 `private`（同既有先例，`private` 以檔案為界，跨檔案 `extension` 存取不到）。
extension ChildrenManagementView {
    func childForID(_ id: UUID) -> Child? {
        childrenStore.children.first { $0.id == id }
    }

    /// 寶貝詳情（`ChildGrowthDetailView`）＋「編輯」入口（推 09b）——`GrowthStore` 由
    /// `ChildGrowthDetailView` 自己的 `@State` 依 `child.id` 決定要不要重建（LS-312 R2，
    /// merge-review R1 M1；見該檔文件註解），這裡只要傳 `child`＋`growthAPIClient` 即可，不再
    /// 自己建 `GrowthStore`。`editDestination` 直接建 `EditChildView`（型別抹除成 `AnyView`），
    /// 不透過 `ChildrenRoute.edit`／`navigationDestination(for:)`——同一顆鈕兩條路徑會重複註冊
    /// 同一個目的地，見 `ChildGrowthDetailView.editDestination` 文件註解「系統 ToolbarItem
    /// 熱區不足 44pt」那個教訓，這裡改用 body content 內的 `NavigationLink(destination:)`。
    func childDetail(for child: Child) -> some View {
        ChildGrowthDetailView(
            child: child, apiClient: growthAPIClient,
            editDestination: childrenStore.canManageChildren
                ? { AnyView(EditChildView(childrenStore: childrenStore, child: child)) }
                : nil
        )
    }
}

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

    /// 寶貝詳情（`ChildGrowthDetailView`）＋「編輯」入口（推 09b）——`GrowthStore` 每次推入都
    /// 新建一份（view-scoped，同 `AlbumDetailStore` 的既有角色分工），不隨 `ChildrenManagementView`
    /// 存活。`editDestination` 直接建 `EditChildView`（型別抹除成 `AnyView`），不透過
    /// `ChildrenRoute.edit`／`navigationDestination(for:)`——同一顆鈕兩條路徑會重複註冊同一個
    /// 目的地，見 `ChildGrowthDetailView.editDestination` 文件註解「系統 ToolbarItem 熱區不足
    /// 44pt」那個教訓，這裡改用 body content 內的 `NavigationLink(destination:)`。
    func childDetail(for child: Child) -> some View {
        ChildGrowthDetailView(
            growthStore: GrowthStore(
                childID: child.id, childName: child.name, childBirthday: child.birthday,
                apiClient: growthAPIClient
            ),
            editDestination: childrenStore.canManageChildren
                ? { AnyView(EditChildView(childrenStore: childrenStore, child: child)) }
                : nil
        )
    }
}

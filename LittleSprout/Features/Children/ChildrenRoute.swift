import Foundation

/// 09 寶貝管理畫面的子路由。`edit` 只帶 `UUID`（不是整個 `Child`）：目的地畫面從
/// `childrenStore.children` 依 id 查目前最新的一筆，避免推入時捕捉到的舊資料在使用者停留
/// 期間過期（例如另一位家人同時編輯）。
enum ChildrenRoute: Hashable {
    case create
    case edit(UUID)
}

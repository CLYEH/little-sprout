import Foundation

/// 09 寶貝管理畫面的子路由。`detail` 只帶 `UUID`（不是整個 `Child`）：目的地畫面從
/// `childrenStore.children` 依 id 查目前最新的一筆，避免推入時捕捉到的舊資料在使用者停留
/// 期間過期（例如另一位家人同時編輯）。
///
/// LS-312 導覽入口接線（orchestrator 裁決）：寶貝列 row 改推 `detail`（「寶貝詳情」，
/// `ChildGrowthDetailView`，稿 `jp6ka`「01 寶貝詳情・成長區塊」）——原本的 `edit` case
/// 已移除：`EditChildView`（09b）現在由 `ChildGrowthDetailView.editDestination` 直接建構
/// （`ChildrenManagementView+Detail.swift`），不再需要走這個路由（同一個目的地不能有兩條
/// 註冊路徑，見該檔文件註解）。
enum ChildrenRoute: Hashable {
    case create
    case detail(UUID)
}

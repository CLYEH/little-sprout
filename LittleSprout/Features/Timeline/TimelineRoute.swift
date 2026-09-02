import Foundation

/// 時間軸的子路由。只帶 id（同 `ChildrenRoute` 的理由，見該檔文件註解）：目的地畫面從
/// `TimelineStore.entries` 依 id 查目前最新的一筆，避免推入時捕捉到的舊資料在使用者停留
/// 期間過期。
enum TimelineRoute: Hashable {
    case diaryDetail(UUID)
}

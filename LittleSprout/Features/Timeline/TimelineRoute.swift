import Foundation

/// 時間軸的子路由。只帶 id（同 `ChildrenRoute` 的理由，見該檔文件註解）：目的地畫面從
/// `TimelineStore.entries` 依 id 查目前最新的一筆，避免推入時捕捉到的舊資料在使用者停留
/// 期間過期。
enum TimelineRoute: Hashable {
    case diaryDetail(UUID)
    /// LS-383：食物卡整張點了 → 記錄詳情 04（`FoodRecordDetailView`）；帶 `food_first` 的 `ref_id`
    /// （＝`child_food_records.id`）。
    case foodRecordDetail(UUID)
    /// LS-383：食物卡 Book Row → 圖鑑 02（`FoodBookView`）並直接選到該類別（Notes `jQp2m`／`Z2z6r6`：
    /// 「導覽到 02 並帶 category（純 UI 狀態）」）。
    case foodBook(childID: UUID, category: FoodCategory)

    /// Book Row 的目的地——那個孩子的圖鑑、選在這項食物的類別（不是圖鑑預設的第一類）。
    static func foodBook(for content: FoodFirstContent) -> TimelineRoute {
        .foodBook(childID: content.record.childID, category: content.item.category)
    }
}

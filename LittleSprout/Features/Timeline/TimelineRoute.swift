import Foundation

/// 時間軸的子路由。只帶 id（同 `ChildrenRoute` 的理由，見該檔文件註解）：目的地畫面從
/// `TimelineStore.entries` 依 id 查目前最新的一筆，避免推入時捕捉到的舊資料在使用者停留
/// 期間過期。
enum TimelineRoute: Hashable {
    case diaryDetail(UUID)
    /// LS-383：食物卡整張點了 → 記錄詳情 04（`FoodRecordDetailRouter`）。R3 起帶推入當下的記錄＋目錄項，不再依
    /// id 回頭查 `TimelineStore.entries`：存檔後的時間軸重讀（force）一換掉 `entries`，查不到就整頁變空。詳情頁的
    /// store 會自己重讀記錄、被刪時返回（`FoodRecordDetailStore.isGone`），所以帶快照不會停在過期資料上。
    case foodRecordDetail(ChildFoodRecord, FoodCatalogItem)
    /// LS-383：食物卡 Book Row → 圖鑑 02（`FoodBookView`）並直接選到該類別（Notes `jQp2m`／`Z2z6r6`：
    /// 「導覽到 02 並帶 category（純 UI 狀態）」）。
    case foodBook(childID: UUID, category: FoodCategory)

    /// Book Row 的目的地——那個孩子的圖鑑、選在這項食物的類別（不是圖鑑預設的第一類）。
    static func foodBook(for content: FoodFirstContent) -> TimelineRoute {
        .foodBook(childID: content.record.childID, category: content.item.category)
    }
}

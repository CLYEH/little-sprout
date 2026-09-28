import Foundation

/// LS-383：`food_first` 相關的時間軸模型——從 `TimelineModels.swift` 拆出（該檔已貼著 SwiftLint `file_length`）。
extension FeedKind {
    /// 這種 kind 能不能留言／按讚——＝是不是後端 `content_target_type` 的成員（`diary`／`album`／
    /// `media`）。`food_first` 不是（LS-325：`comment_count` 恆 0，`get_reaction_counts`／`toggle_reaction`
    /// 傳 `food_first` 會撞 enum 轉型錯誤），v1 食物卡不畫互動列、`TimelineStore.loadReactionCounts`
    /// 也不替它發查詢（LS-383 範圍 4、稿 `SLjde` Design Note）。
    var supportsInteractions: Bool {
        switch self {
        case .diary, .album, .media: return true
        case .foodFirst, .unknown: return false
        }
    }
}

/// LS-383：時間軸「第一次吃到〇〇」卡片（`cmp/Card Food First` `SBzKx`）的內容——`get_family_timeline`
/// `food_first` 指標 → `child_food_records` 一筆（食物、寶貝、日期、反應、一句話、照片 id）＋
/// `food_catalog` 那一項（名稱、類別）＋照片（有 `media_id` 且讀得到時；走時間軸既有的 media 縮圖簽名，
/// 見 `TimelineContentAssembler.fetchFoodFirstContents`）。整筆記錄與目錄項原樣帶著，點卡片開記錄詳情
/// （`FoodRecordDetailView` 吃的就是這兩個型別）不必再查一次。
struct FoodFirstContent: Equatable, Sendable {
    let record: ChildFoodRecord
    let item: FoodCatalogItem
    /// `nil`＝沒有照片，或照片已被軟刪／讀不到（`media_select` 不回傳）——卡片都不畫照片區。
    let photo: MediaContent?
}

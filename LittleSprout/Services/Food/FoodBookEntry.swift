import Foundation

/// 寶貝詳情「飲食圖鑑」入口（LS-382，`design/littlesprout.pen` 01 `QRoGt`／01b `J58vyP`／01c `ls2g6`／
/// 01-iPad `h5PBGH`）的一格：食物＋那一筆記錄（nil＝還沒吃，補位用的空位）。
struct FoodBookEntrySlot: Equatable, Identifiable {
    let item: FoodCatalogItem
    let record: ChildFoodRecord?

    var id: String { item.id }
}

/// 01 家族的填格規則與文案——抽成純函式讓 `FoodBookEntryTests` 不建 View 就能鎖住（同 `FoodBookCopy`）。
///
/// 填法（Notes `hqrit` 狀態段最後一句）：「已吃過的依 first_tried_on 新到舊先排；不足三格時，依
/// food_catalog.sort_order 補上還沒吃的空位（點了開 03）……三種筆數的區塊高度相同。」iPad 同規則五格
/// （Notes `KqOZI`「最近 5 格」、`qd7nA`「五格同規則」）。
enum FoodBookEntry {
    static let compactSlotCount = 3
    static let regularSlotCount = 5

    /// `catalog` 是目錄（`active = true`）；記錄指向目錄裡找不到的食物（已下架）時不佔格——同
    /// `FoodBookStore.triedCount` 的分子規則，格子上看得到的紙片數才跟計數句一致。
    ///
    /// 同一天吃到好幾樣時依 `created_at` 新到舊（後記的在前），再依 `sort_order`——排序必須全序，
    /// 否則同日的幾格每次重繪可能換位置。
    static func slots(catalog: [FoodCatalogItem], records: [ChildFoodRecord], count: Int) -> [FoodBookEntrySlot] {
        let sortedCatalog = catalog.sorted { $0.sortOrder < $1.sortOrder }
        let itemsByID = Dictionary(sortedCatalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seenFoodIDs = Set<String>()
        let tried = records
            .compactMap { record -> FoodBookEntrySlot? in
                guard let item = itemsByID[record.foodID], seenFoodIDs.insert(record.foodID).inserted else {
                    return nil
                }
                return FoodBookEntrySlot(item: item, record: record)
            }
            .sorted(by: isMoreRecent)
        let triedSlots = Array(tried.prefix(count))
        let untried = sortedCatalog
            .lazy
            .filter { !seenFoodIDs.contains($0.id) }
            .prefix(count - triedSlots.count)
            .map { FoodBookEntrySlot(item: $0, record: nil) }
        return triedSlots + untried
    }

    private static func isMoreRecent(_ lhs: FoodBookEntrySlot, _ rhs: FoodBookEntrySlot) -> Bool {
        guard let left = lhs.record, let right = rhs.record else { return false }
        if left.firstTriedOn != right.firstTriedOn { return left.firstTriedOn > right.firstTriedOn }
        if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
        return lhs.item.sortOrder < rhs.item.sortOrder
    }

    /// 計數句（逐字對稿）：
    /// - 全部格子都是吃過的：「小安吃過 38／274 種，最近三樣：」（01 `MQ01U`；iPad「最近五樣」`w25F3`）
    /// - 一格都還沒吃：「小安吃過 0／274 種，可以從這三樣開始：」（01b `A79NZ`）
    /// - 兩者都有：「小安吃過 1／274 種，最近和接著試的：」（01c `fKTwC`）
    ///
    /// 「種」前是 U+00A0（稿面 codepoint，Notes MN-13）；`String(_:)` 先轉字串，理由同
    /// `FoodBookCopy.progressSentence`。
    static func countLine(childName: String, triedCount: Int, totalCount: Int, slots: [FoodBookEntrySlot]) -> String {
        let head = "\(childName)吃過 \(String(triedCount))／\(String(totalCount))\u{00A0}種，"
        let triedSlots = slots.filter { $0.record != nil }.count
        let amount = chineseNumeral(slots.count)
        if triedSlots == slots.count { return head + "最近\(amount)樣：" }
        if triedSlots == 0 { return head + "可以從這\(amount)樣開始：" }
        return head + "最近和接著試的："
    }

    /// 次要鈕文字：還沒有任何記錄＝「打開飲食圖鑑」（01b `LrKtH`）；AX 字級＝「看整本圖鑑」（A11y/01 `Gke1S`）；
    /// 其餘「看整本飲食圖鑑」（01 `CTlLJ`）。
    static func bookButtonTitle(triedCount: Int, isAccessibilityLayout: Bool) -> String {
        if triedCount == 0 { return "打開飲食圖鑑" }
        return isAccessibilityLayout ? "看整本圖鑑" : "看整本飲食圖鑑"
    }

    private static func chineseNumeral(_ value: Int) -> String {
        let numerals = ["零", "一", "二", "三", "四", "五"]
        return numerals.indices.contains(value) ? numerals[value] : String(value)
    }
}

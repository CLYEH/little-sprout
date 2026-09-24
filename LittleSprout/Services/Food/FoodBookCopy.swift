import Foundation

/// cmp/Food Cell（`design/littlesprout.pen` `IikhF`）一格的三種狀態——LS-326 Notes `h752D`「紙＝吃過了」、
/// `J8qvq5`（viewer 權限）。
///
/// - `tried`：`$print-paper` 紙片＋彩色貼紙＋日期；可點（開記錄詳情，LS-381）——viewer 也可以看詳情
///   （Notes `J8qvq5`「其他成員看詳情不顯示任何動作」＝看得到、沒有動作鈕）。
/// - `untried`：透明底＋`$border` 髮絲框＋灰階貼紙；可點（開第一次記錄 sheet，LS-380）。
/// - `untriedReadOnly`：viewer（02c `jo5h8`）的空位——連髮絲框都拿掉，**不是按鈕**。
enum FoodCellState: Equatable {
    case tried(firstTriedOn: Date)
    case untried
    case untriedReadOnly

    /// `canRecord`＝目前登入者能不能新增記錄（owner／member；viewer 為 false，同
    /// `ChildrenStore.canManageChildren`，`child_food_records_insert` RLS 只認 owner／member）。
    static func make(record: ChildFoodRecord?, canRecord: Bool) -> FoodCellState {
        if let record { return .tried(firstTriedOn: record.firstTriedOn) }
        return canRecord ? .untried : .untriedReadOnly
    }

    var isTried: Bool {
        if case .tried = self { return true }
        return false
    }

    /// 這一格是不是按鈕——只有 viewer 的空位不是（Notes `J8qvq5`「空位……不是按鈕」）。
    var isInteractive: Bool { self != .untriedReadOnly }
}

/// 飲食圖鑑 02 家族（`hWu6N`／`SYefI`／`jo5h8`）的文案與字串格式——抽成純函式讓
/// `FoodBookCopyTests` 不建 View 就能鎖住逐字文案與對映表。
enum FoodBookCopy {
    /// 計數句（Notes MN-13：數字與「種」之間是 U+00A0，避免 AX3 下「種」被單獨折到下一行）。
    /// `String(_:)` 先轉字串再插值——`Text` 對 `Int` 插值會套預設數字格式（千分位），同
    /// `GrowthRecordsListView.yearDivider(_:)` 的既有教訓。
    static func progressSentence(childName: String, triedCount: Int, totalCount: Int) -> String {
        "\(childName)吃過 \(String(triedCount))\u{00A0}種，全部 \(String(totalCount))\u{00A0}種。"
    }

    /// 類別標題右側「吃過 N／M」（全形斜線，稿面 `raups` 逐字）。
    static func categoryCount(triedCount: Int, totalCount: Int) -> String {
        "吃過 \(String(triedCount))／\(String(totalCount))"
    }

    /// 類別標題下的一句提示：owner／member（02 `nO7yz`）與 viewer（02c `UbcMH`）各一句。
    static func tapHint(canRecord: Bool) -> String {
        canRecord ? "點灰色的格子，就能記下第一次吃到的日子。" : "這本圖鑑由家人記錄，你可以隨時翻看。"
    }

    /// 免責句（02 Disclaimer `r3uREQ` 逐字），固定排在格子之後。
    static let disclaimer = "標「含〇〇」的是常見過敏原，標「一歲後」的建議滿一歲再吃。這些只是提醒，不是醫療建議；有疑問請問醫師。"

    /// AX3 橫排清單空位的可見文字；VoiceOver 兩種字級都唸（Notes `vMFj3`「還沒吃過」規則）。
    static let untriedText = "還沒吃過"

    /// `food_catalog.allergens` 值 → 格子小標用名（Notes `v5KLRQ` 對應表逐字；`wheat` 在格子上是
    /// 「含麩質」，詳情頁的長版「含麩質（小麥、燕麥等穀物）」屬 LS-381）。
    static let allergenNames: [String: String] = [
        "egg": "蛋", "milk": "牛奶", "peanut": "花生", "tree_nut": "堅果", "shellfish": "甲殼類",
        "fish": "魚", "wheat": "麩質", "soy": "大豆", "sesame": "芝麻", "mango": "芒果"
    ]

    /// 格子上的過敏原小標：無過敏原＝nil（整列不顯示）；一種＝「含〇〇」；多種＝「第一種＋等」
    /// （Notes `v5KLRQ`：布丁 `milk;egg` ＝「含牛奶等」）。純資訊，不帶警告圖示（F2a）。
    /// 未知代碼（DB CHECK 之外，理論上不會出現）退回「含過敏原」，不讓英文代碼露出在畫面上。
    static func allergenTag(_ allergens: [String]) -> String? {
        guard let first = allergens.first else { return nil }
        let name = allergenNames[first] ?? "過敏原"
        return allergens.count > 1 ? "含\(name)等" : "含\(name)"
    }

    /// 「一歲後」小標：`min_age_months = 12`（目前 catalog 唯一的非 null 值）。**不看孩子年齡**——
    /// 滿一歲後仍顯示（使用者 09-24 裁 D1a，Notes 02b `E2qFT6`），所以這支函式刻意不收生日參數。
    /// 其他月數（目前不存在）照實寫出月數，不默默吞掉。
    static func ageTag(minAgeMonths: Int?) -> String? {
        guard let minAgeMonths else { return nil }
        return minAgeMonths == 12 ? "一歲後" : "滿\(String(minAgeMonths))個月後"
    }

    /// 格子日期 yyyy/M/d（不補零；Notes `vMFj3` MN-1）。`firstTriedOn` 是 UTC 午夜（同
    /// `ChildFoodRecord` 解碼），用 UTC＋固定西曆抽年月日——裝置曆法設成民國曆也不會印出 115 年
    /// （同 `BirthdayFormat` LS-331 的教訓）。
    static func cellDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(String(parts.year ?? 0))/\(String(parts.month ?? 0))/\(String(parts.day ?? 0))"
    }

    /// 一格的 VoiceOver 標籤：名稱、日期或「還沒吃過」、兩個小標依序唸出。
    static func cellAccessibilityLabel(item: FoodCatalogItem, state: FoodCellState) -> String {
        var parts = [item.nameZh]
        if case .tried(let date) = state {
            parts.append("\(cellDate(date)) 第一次吃到")
        } else {
            parts.append(untriedText)
        }
        if let allergen = allergenTag(item.allergens) { parts.append(allergen) }
        if let age = ageTag(minAgeMonths: item.minAgeMonths) { parts.append(age) }
        return parts.joined(separator: "，")
    }
}

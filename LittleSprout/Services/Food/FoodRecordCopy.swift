import Foundation

/// 03 第一次記錄 sheet 家族（`design/littlesprout.pen` `FP2An`／`ekxHM`／`Oob1d`／`OoYLu`／`NgnYl`）
/// 的文案與字串格式——抽成純函式讓 `FoodRecordCopyTests` 不建 View 就能鎖住逐字文案。
enum FoodRecordCopy {
    /// 表頭（稿 `ozOlF`「記下小安第一次吃芋頭」／03b `r3f21`「編輯吐司麵包這筆記錄」）。〇〇＝`children.name`
    /// （Notes `jQp2m`：暱稱就是 `children.name`，同 LS-379 計數句）。
    static func headTitle(childName: String, foodName: String, isEditing: Bool) -> String {
        isEditing ? "編輯\(foodName)這筆記錄" : "記下\(childName)第一次吃\(foodName)"
    }

    /// 反應欄標題（稿 `lqy15`）。
    static func reactionLabel(childName: String) -> String { "\(childName)覺得怎麼樣（可不選）" }

    static let dateLabel = "哪一天第一次吃"
    static let dateHelp = "忘了記也沒關係，可以選以前的日子。"
    static let notePlaceholder = "例如：一口接一口，吃光光。"

    /// 日期欄（Notes `vMFj3` MN-1）：sheet 用 yyyy年M月d日，今天省年並加「（今天）」（稿 `HqOAw`「8月20日
    /// （今天）」、03b `XDLD2`「2026年6月8日」）；AX 字級明確斷兩行（稿 `ytz0J`「8月20日\n（今天）」、
    /// A11y/03b `zwAsn`「2026年\n6月8日」），不讓系統在字中間斷。固定西曆（裝置曆法設民國曆也不印
    /// 115 年，同 `FoodBookCopy.cellDate`）；`date` 是裝置本地時區的某一天（DatePicker 的值）。
    static func dateValue(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current, twoLines: Bool) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let monthDay = "\(String(parts.month ?? 0))月\(String(parts.day ?? 0))日"
        let separator = twoLines ? "\n" : ""
        if calendar.isDate(date, inSameDayAs: now) { return "\(monthDay)\(separator)（今天）" }
        return "\(String(parts.year ?? 0))年\(separator)\(monthDay)"
    }

    /// Status Slot 平時的一句（稿 `JBWqy`／03b `UtXVy`）。
    static func statusNormal(foodName: String, isEditing: Bool) -> String {
        isEditing ? "改好後按「儲存」，時間軸上的卡片也會跟著更新。" : "儲存後\(foodName)會變成彩色，家人也會在時間軸看到這一刻。"
    }

    /// 03e 失敗句（稿 `RYjog`，失敗文案鍵 `food.save_failed`）——斷線是稿面畫的那一句。
    static let saveFailedNetwork = "沒有存起來：網路好像斷了。填好的內容都還在，連上網路後再按一次「儲存」。"

    /// 其餘碼（42501／LS044／LS051／LS052／LS053／23514…）共用 Status Slot（Notes `uubmW`「其餘碼共用
    /// Status Slot」）：同一個開頭「沒有存起來：」＋既有四層錯誤文法的使用者文案（`AppError.userFacingMessage`，
    /// 不把後端原始訊息上螢幕）。
    static func saveFailed(_ error: AppError) -> String {
        if case .network = error { return saveFailedNetwork }
        return "沒有存起來：\(error.userFacingMessage)"
    }

    /// 「從手機加入」選到 Storage 不收的格式（`PickedItemLoader.LoadedItem.unsupportedFormat`）或讀不出
    /// 照片時——稿面沒畫這個邊界，沿 03e 的 Status Slot 失敗語彙（同一格、同一套開頭），不另開版面。
    static let photoUnsupported = "沒有加入照片：這張照片讀不出來，請換一張。"

    /// 03b 原照片縮圖讀不到（已軟刪／網路；merge-review R1 i4）——照片仍會保留，要拿掉請按「不用照片」。
    static let existingPhotoUnavailable = "原照片讀取失敗"

    /// 03c 刪除確認（稿 `F7KFM`／`jbiJI` 逐字；票文範圍 3）。
    static func deleteTitle(foodName: String) -> String { "要刪除\(foodName)這筆記錄嗎？" }
    static func deleteBody(foodName: String) -> String {
        "\(foodName)會變回灰色，時間軸上的卡片也會拿掉。照片會留在家庭相簿。"
    }

    /// 06「收下」動效播放時 VoiceOver 唸一次（Notes `cEkCH`「VoiceOver 唸『已記下〇〇』」）。
    static func revealAnnouncement(foodName: String) -> String { "已記下\(foodName)" }
}

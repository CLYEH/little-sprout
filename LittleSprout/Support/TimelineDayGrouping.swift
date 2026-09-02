import Foundation

/// 時間軸 Day Divider 日分組（LS-126 票文 Scope 1）——純函式，依 `occurredAt` 落在同一個
/// （裝置本地時區）自然日的項目分成一組，組內維持 `get_family_timeline` 已經排好的順序
/// （`occurred_at desc, ref_id desc`）不重排、不排序，只切邊界。
///
/// 同一組內的卡片間距 16（`$sp-item`）、跨組（換日）間距 44（`$sp-section`）——這兩個數字
/// 由呼叫端（`TimelineView`）套用，本型別只負責切出組的邊界。
enum TimelineDayGrouping {
    struct Group: Identifiable, Equatable {
        /// 這一組的自然日（`calendar.startOfDay(for:)`），同時是 Day Divider 顯示用的日期
        /// 與 `Identifiable` 的 id。
        let day: Date
        let entries: [TimelineEntry]

        var id: Date { day }
    }

    /// 分頁載入時（`loadMore`）新的一頁若第一筆跟目前最後一組同一天，呼叫端應該把新的一頁
    /// 對「目前累積的完整 entries 陣列」重跑本函式（而不是只對新頁面單獨分組再接起來）——
    /// 見 `TimelineView` 呼叫處註解，避免同一天被切成兩個 Day Divider。
    static func group(_ entries: [TimelineEntry], calendar: Calendar = .current) -> [Group] {
        var groups: [Group] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.occurredAt)
            if let last = groups.last, calendar.isDate(last.day, inSameDayAs: day) {
                groups[groups.count - 1] = Group(day: last.day, entries: last.entries + [entry])
            } else {
                groups.append(Group(day: day, entries: [entry]))
            }
        }
        return groups
    }
}

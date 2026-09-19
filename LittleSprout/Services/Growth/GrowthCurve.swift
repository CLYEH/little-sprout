import Foundation

/// 成長曲線純函式（LS-312，`design/littlesprout.pen` Notes 板 `h5BNyi`→`O7e9Ho`／`hv1vr`）：
/// 月齡計算、同日多筆取最後、缺值處理、最新值＋較上次差值、Y 軸格線、X 軸刻度密度。全部不依賴
/// SwiftUI／Store／網路，供 `GrowthCurveTests` 直接驗證邊界情境（閏月／未滿月／生日當天／缺值／
/// 同日多筆取最後）——`GrowthStore`／`GrowthChartCardView` 只轉呼叫，不重複算一次。
enum GrowthCurve {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Notes `MNEXN`：`ageMonths = (measured.year−birthday.year)×12 +
    /// (measured.month−birthday.month) − (measured.day<birthday.day ? 1 : 0)`。用日曆整月數，
    /// 不是天數/30 近似——`birthday`／`measuredOn` 皆為 `BirthdayFormat`／`GrowthRecord` 既有
    /// 慣例的 UTC 午夜 `Date`。
    static func ageInMonths(birthday: Date, measuredOn: Date) -> Int {
        let calendar = utcCalendar
        let birthdayComponents = calendar.dateComponents([.year, .month, .day], from: birthday)
        let measuredComponents = calendar.dateComponents([.year, .month, .day], from: measuredOn)
        guard let birthYear = birthdayComponents.year, let birthMonth = birthdayComponents.month,
              let birthDay = birthdayComponents.day, let measuredYear = measuredComponents.year,
              let measuredMonth = measuredComponents.month, let measuredDay = measuredComponents.day
        else { return 0 }
        var months = (measuredYear - birthYear) * 12 + (measuredMonth - birthMonth)
        if measuredDay < birthDay { months -= 1 }
        return months
    }

    /// 同一天若有多筆記錄（`growth_records` 沒有 `unique(child_id, measured_on)` 限制，理論上
    /// 可能發生），取「最後一筆」：以 `updatedAt` 最新者為準（同一天內容被覆寫過，最後一次寫入
    /// 才是使用者現在認定的量測結果），`updatedAt` 相同時以 `id` 字串排序當決定性 tie-break
    /// （純函式必須是決定性的，不能依賴輸入陣列的原始順序）。回傳依 `measuredOn` 遞增排序。
    static func deduplicatedByDay(_ records: [GrowthRecord]) -> [GrowthRecord] {
        let grouped = Dictionary(grouping: records) { utcCalendar.startOfDay(for: $0.measuredOn) }
        return grouped.values.compactMap { group in
            group.max { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }.sorted { $0.measuredOn < $1.measuredOn }
    }

    struct CurvePoint: Equatable {
        let ageMonths: Int
        let value: Double
        let measuredOn: Date
    }

    /// R1 merge-review M2：曲線／最新值卡不能沿用 `deduplicatedByDay`（整筆同日去重）——同一天
    /// 先存身高、再存體重是兩筆不同記錄，整筆去重只留下「體重那一筆」，身高那筆的值就此消失，
    /// 即使身高在那天確實有量到。改成**逐項**去重：只在同一天、同一個量測項出現多筆時才需要
    /// 決定代表值，取 `createdAt` 最新的一筆（`createdAt` 相同時以 `id` 字串排序 tie-break，
    /// 同 `deduplicatedByDay` 的既有決定性理由）。
    private static func latestValuesByDay(
        for metric: GrowthMetric, records: [GrowthRecord]
    ) -> [(record: GrowthRecord, value: Double)] {
        let withValue: [(record: GrowthRecord, value: Double)] = records.compactMap { record in
            guard let value = metric.value(in: record) else { return nil }
            return (record, value)
        }
        let grouped = Dictionary(grouping: withValue) { utcCalendar.startOfDay(for: $0.record.measuredOn) }
        return grouped.values.compactMap { group in
            group.max { lhs, rhs in
                if lhs.record.createdAt != rhs.record.createdAt { return lhs.record.createdAt < rhs.record.createdAt }
                return lhs.record.id.uuidString < rhs.record.id.uuidString
            }
        }
    }

    /// 給定量測項與 `birthday`，取該項「有值」的曲線點，依月齡遞增排序（Notes `C46vnG`：
    /// 「三條曲線各自獨立取點」——身高／體重／頭圍互不影響彼此的缺值）。呼叫端在少於 2 點時
    /// 不畫折線（Notes「少於 2 個有效資料點時不畫折線」，見 04 空狀態骨架版）。
    static func curvePoints(for metric: GrowthMetric, records: [GrowthRecord], birthday: Date) -> [CurvePoint] {
        latestValuesByDay(for: metric, records: records).map { entry in
            CurvePoint(
                ageMonths: ageInMonths(birthday: birthday, measuredOn: entry.record.measuredOn),
                value: entry.value, measuredOn: entry.record.measuredOn
            )
        }.sorted { $0.ageMonths < $1.ageMonths }
    }

    struct LatestValue: Equatable {
        let record: GrowthRecord
        let value: Double
        /// 正值＝比上一筆（有值）高／重／大；負值＝比上一筆低／輕／小；`nil`＝這項量測只有
        /// 這一筆記錄，沒有「上一筆」可比較。
        let delta: Double?
    }

    /// 「最新值卡」（Notes `qga6d`／`db1ET`）：該項量測「有值」的最新一筆記錄，與上一筆
    /// 「有值」的記錄算差值——**不是相鄰整筆**：某次記錄缺這一項，往前找的是「上一筆有值」的
    /// 記錄，不是陣列相鄰那一筆（例：13mo 缺身高，16mo 身高的『上一筆』是 10mo，不是 13mo）。
    /// 逐項去重理由見 `latestValuesByDay` 文件註解（M2）。
    static func latestValue(for metric: GrowthMetric, records: [GrowthRecord]) -> LatestValue? {
        let withValue = latestValuesByDay(for: metric, records: records)
            .sorted { $0.record.measuredOn > $1.record.measuredOn }
        guard let latest = withValue.first else { return nil }
        let delta = withValue.count > 1 ? latest.value - withValue[1].value : nil
        return LatestValue(record: latest.record, value: latest.value, delta: delta)
    }

    /// Y 軸格線：4 條，均分「值域 + 15% 邊距」的區間（遞增排序）。抄值表 `wgF5u` 列的
    /// `[85,70,55,40]` 是示範資料集「身高」這一項算出來的結果——體重（kg）／頭圍（cm）的數值
    /// 範圍完全不同，三項切換必須動態算格線，不能整段照抄那組硬值（PR「已完成」欄註記這個
    /// 取捨）。輸入為空回傳空陣列（04 骨架版呼叫端改用固定的示意格線，不呼叫這支）。
    static func gridlines(values: [Double]) -> [Double] {
        guard let minValue = values.min(), let maxValue = values.max() else { return [] }
        let span = max(maxValue - minValue, 0.0001)
        let padding = span * 0.15
        let lower = minValue - padding
        let upper = maxValue + padding
        let step = (upper - lower) / 3
        return (0...3).map { lower + step * Double($0) }
    }

    /// 06 iPad「歷史紀錄」（Notes `jrsot`，`GrowthHistorySection` 唯一呼叫端）純顯示列表的順序：
    /// 同日整筆去重後依 `measuredOn` 遞減（最新在最上面）。R2 merge-review i1（記入 LS-96）：
    /// 06 仍是整筆去重，同一天兩筆會漏列其中一筆——03（`GrowthRecordsListView`）已改用不去重的
    /// `allRecordsNewestFirst`，不再共用這支。
    static func historyRecords(_ records: [GrowthRecord]) -> [GrowthRecord] {
        deduplicatedByDay(records).sorted { $0.measuredOn > $1.measuredOn }
    }

    /// R2 merge-review R2-m1（orchestrator 裁決 `8036a6f0`）：03 列表「同日多筆全列、不去重」
    /// 的排序邏輯抽成純函式，讓 `GrowthRecordsListView.rowItems` 只轉呼叫、不在 View 內重複
    /// 實作——View 是 private computed var，沒有 ViewInspector 測不到，這支純函式可以直接測，
    /// 呼叫點是否真的改回整筆去重的 `historyRecords` 則另外用原始碼字面守衛驗證（見
    /// `GrowthRecordsRowOrderRegressionTests`）。依 `measuredOn` 遞減排序，同日以 `createdAt`
    /// 遞減 tie-break（較晚存的排前面，同 `latestValuesByDay` 的 tie-break 依據一致，不是任意
    /// 選一個）。
    static func allRecordsNewestFirst(_ records: [GrowthRecord]) -> [GrowthRecord] {
        records.sorted { lhs, rhs in
            if lhs.measuredOn != rhs.measuredOn { return lhs.measuredOn > rhs.measuredOn }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// X 軸刻度密度（Notes `hv1vr`）：一般字級全部標出；AX3 密度改「每隔一個標（含首尾）」——
    /// 先用 step 2 從頭取樣，若最後一次取樣沒有剛好落在真正的最後一點，用最後一點**取代**取樣
    /// 到的最後一個索引（不是額外新增，保持「只標約半數」的密度目的）。例：6 個資料點在 AX3
    /// 只標索引 0/2/5（對應月齡 1/7/16，逐字對齊 Notes 舉例）。
    static func xAxisLabelIndices(pointCount: Int, isCompactDensity: Bool) -> [Int] {
        guard pointCount > 0 else { return [] }
        guard isCompactDensity, pointCount > 2 else { return Array(0..<pointCount) }
        var indices = Array(stride(from: 0, to: pointCount, by: 2))
        if let lastPicked = indices.last, lastPicked != pointCount - 1 {
            indices[indices.count - 1] = pointCount - 1
        }
        return indices
    }
}

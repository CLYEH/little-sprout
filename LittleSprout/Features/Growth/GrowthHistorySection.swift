import SwiftUI

/// 06 iPad「歷史紀錄」——兩欄年份分組（Notes `jrsot`／`ZiUDD`：「歷史紀錄改兩欄年份分組
/// （沿用 cmp/Day Divider 年份郵戳，與 03 一致）」）。`cmp/Day Divider`／`cmp/Growth Record
/// Row` 尚未正式元件化（2/2〔LS-313〕記錄列表才會做，見 Notes `Q4b9X`「兩處手動同步」）——
/// 這裡先用本檔的輕量版年份郵戳／紀錄列自行實作，不預先假造一個共用元件（YAGNI：等 2/2 真的
/// 也要用時再抽共用，現在抽只會抽錯形狀）。
///
/// 分欄規則（Notes 示範資料集驗證：2026 年 3 筆進左欄、2025 年 3 筆進右欄，逐字對齊
/// Notes `GPsuf`／`mt8yZ`）：依年份遞減分組，年份群組輪流分派到左右欄（第 1 個年份群組
/// 進左欄、第 2 個進右欄、第 3 個再回左欄接在下面……）。Notes 只示範了剛好兩個年份的情境，
/// 三個年份以上的分欄行為是本票的工程判斷，不是逐字規格（PR「已完成」欄註記）。
struct GrowthHistorySection: View {
    let records: [GrowthRecord]

    private var yearGroups: [(year: Int, records: [GrowthRecord])] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let ordered = GrowthCurve.historyRecords(records)
        let grouped = Dictionary(grouping: ordered) { calendar.component(.year, from: $0.measuredOn) }
        return grouped.keys.sorted(by: >).map { year in
            (year, grouped[year]?.sorted { $0.measuredOn > $1.measuredOn } ?? [])
        }
    }

    private var columnA: [(year: Int, records: [GrowthRecord])] {
        yearGroups.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
    }

    private var columnB: [(year: Int, records: [GrowthRecord])] {
        yearGroups.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.item) {
            column(columnA)
            column(columnB)
        }
    }

    @ViewBuilder
    private func column(_ groups: [(year: Int, records: [GrowthRecord])]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.group) {
            ForEach(groups, id: \.year) { group in
                GrowthYearDivider(year: group.year)
                ForEach(group.records) { record in
                    GrowthHistoryRow(record: record)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 年份郵戳（Notes：「沿用 cmp/Day Divider 年份郵戳」）——輕量版，只印年份本身，不含月份／
/// 日期（那是每一列 `GrowthHistoryRow` 自己的 `measuredOnHistoryLabel`）。
private struct GrowthYearDivider: View {
    let year: Int

    var body: some View {
        Text(String(year))
            .appFont(.meta, weight: .bold)
            .foregroundStyle(Color.lsTextSecondary)
            .padding(.horizontal, AppSpacing.group)
            .padding(.vertical, AppSpacing.tight)
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsBorder, lineWidth: 1)
            )
    }
}

/// 單筆歷史紀錄列（Notes `jfEiL` 等）：日期標題＋逐項「有值」的量測（身高／體重／頭圍，
/// 缺值的項目不顯示那一行）。
private struct GrowthHistoryRow: View {
    let record: GrowthRecord

    private var presentMetrics: [(metric: GrowthMetric, value: Double)] {
        GrowthMetric.allCases.compactMap { metric in
            metric.value(in: record).map { (metric, $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            Text(record.measuredOnHistoryLabel)
                .appFont(.note)
                .foregroundStyle(Color.lsTextPrimary)
            ForEach(presentMetrics, id: \.metric) { entry in
                HStack(spacing: AppSpacing.tight) {
                    Image(systemName: entry.metric.systemImage)
                        .appIconFrame(.small)
                        .foregroundStyle(Color.lsTextSecondary)
                    Text(entry.metric.label)
                        .appFont(.meta)
                        .foregroundStyle(Color.lsTextSecondary)
                    Text("\(entry.metric.formattedValue(entry.value)) \(entry.metric.unit)")
                        .appFont(.meta)
                        .foregroundStyle(Color.lsTextPrimary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.group)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
    }
}

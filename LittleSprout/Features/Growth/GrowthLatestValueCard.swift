import SwiftUI

/// 「最新值卡」三格之一（身高／體重／頭圍，Notes `qga6d`／`db1ET`）。`latest == nil` 時渲染 04
/// 空狀態的空欄位卡（`—`／`尚無紀錄`，Notes `HdYFt` 等），同一支 View 涵蓋兩態——不另開檔案，
/// 差異只在幾個文字／色彩分支，拆兩支 View 反而更難維護同步。
struct GrowthLatestValueCard: View {
    let metric: GrowthMetric
    let latest: GrowthCurve.LatestValue?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            labelRow
            valueRow
            deltaRow
            Text(latest.map { "\($0.record.measuredOnShortLabel) 測量" } ?? "尚無紀錄")
                .appFont(.meta)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.item)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        .accessibilityElement(children: .combine)
    }

    private var labelRow: some View {
        HStack(spacing: AppSpacing.tight) {
            Image(systemName: metric.systemImage)
                .appIconFrame(.small)
                .foregroundStyle(Color.lsTextSecondary)
            Text(metric.label)
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    @ViewBuilder
    private var valueRow: some View {
        if let latest {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.tight) {
                Text(metric.formattedValue(latest.value))
                    .appFont(.lead, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                Text(metric.unit)
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
        } else {
            Text("—")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    /// 有上一筆可比較才顯示箭頭＋差值；只有一筆記錄（`delta == nil`）或空狀態都顯示灰色
    /// 佔位橫槓，維持三張卡高度一致（04 骨架版「Delta Row Placeholder」與這裡共用同一個
    /// 佔位分支，不需要另外判斷 04／01）。
    @ViewBuilder
    private var deltaRow: some View {
        HStack(spacing: AppSpacing.tight) {
            if let delta = latest?.delta {
                Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .appIconFrame(.small)
                    .foregroundStyle(Color.lsTextSecondary)
                Text(metric.formattedDelta(delta))
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            } else {
                Image(systemName: "minus")
                    .appIconFrame(.small)
                    .foregroundStyle(Color.lsBorder)
            }
        }
    }
}

#Preview("有資料") {
    GrowthLatestValueCard(
        metric: .height,
        latest: GrowthCurve.latestValue(
            for: .height,
            records: [
                GrowthRecord(
                    id: UUID(), familyID: UUID(), childID: UUID(), authorID: UUID(),
                    measuredOn: BirthdayFormat.date(fromWireString: "2026-08-20")!, heightCm: 78.5,
                    weightKg: nil, headCm: nil, note: nil, createdAt: Date(), updatedAt: Date()
                )
            ]
        )
    )
    .padding()
}

#Preview("空狀態") {
    GrowthLatestValueCard(metric: .height, latest: nil)
        .padding()
}

import Foundation
@testable import LittleSprout
import XCTest

/// `GrowthCurve`：月齡計算邊界（閏月／未滿月／生日當天）、缺值處理、同日多筆取最後、
/// 與上次差 ▲▼ 符號、Y 軸格線、X 軸刻度密度（LS-312 驗收條件第一項）。
final class GrowthCurveTests: XCTestCase {
    private func date(_ wire: String) -> Date {
        BirthdayFormat.date(fromWireString: wire)!
    }

    private func record(
        id: UUID = UUID(), measuredOn: String, height: Double? = nil, weight: Double? = nil,
        head: Double? = nil, updatedAt: Date = Date()
    ) -> GrowthRecord {
        GrowthRecord(
            id: id, familyID: UUID(), childID: UUID(), authorID: UUID(), measuredOn: date(measuredOn),
            heightCm: height, weightKg: weight, headCm: head, note: nil, createdAt: updatedAt, updatedAt: updatedAt
        )
    }

    // MARK: - ageInMonths 邊界

    /// 閏月：2024 是閏年，2024-02-29 出生，2025-03-01 量測——跨過 2024-02-29 這個閏日，
    /// 用日曆整月數（2025-2024)*12 + (3-2) - (1<29?1:0) = 12+1-1 = 12。
    func test_ageInMonths_leapMonthBoundary() {
        let birthday = date("2024-02-29")
        let measured = date("2025-03-01")

        XCTAssertEqual(GrowthCurve.ageInMonths(birthday: birthday, measuredOn: measured), 12)
    }

    /// 未滿月：出生後 20 天，還沒滿 1 個月——月數要算 0，不能因為 day 比較而算成負數或跳過。
    func test_ageInMonths_underOneMonth_returnsZero() {
        let birthday = date("2026-08-01")
        let measured = date("2026-08-21")

        XCTAssertEqual(GrowthCurve.ageInMonths(birthday: birthday, measuredOn: measured), 0)
    }

    /// 生日當天量測（滿 N 個月整）：day 相等不觸發「未滿月」扣一，票文 Notes `bQb5X` 範例
    /// （16mo＝2026-08-20，出生 2025-04-20）逐字對齊。
    func test_ageInMonths_exactBirthdayAnniversary() {
        let birthday = date("2025-04-20")
        let measured = date("2026-08-20")

        XCTAssertEqual(GrowthCurve.ageInMonths(birthday: birthday, measuredOn: measured), 16)
    }

    /// 量測日的「日」小於生日的「日」——扣一個月，不能整月數溢算。
    func test_ageInMonths_measuredDayBeforeBirthDay_subtractsOneMonth() {
        let birthday = date("2025-04-20")
        let measured = date("2026-08-19")

        XCTAssertEqual(GrowthCurve.ageInMonths(birthday: birthday, measuredOn: measured), 15)
    }

    // MARK: - 同日多筆取最後

    func test_deduplicatedByDay_sameDayMultipleRecords_keepsLatestUpdatedAt() {
        let earlyUpdate = date("2026-01-01")
        let laterUpdate = date("2026-01-02")
        let older = record(measuredOn: "2026-05-20", height: 70.0, updatedAt: earlyUpdate)
        let newer = record(measuredOn: "2026-05-20", height: 71.5, updatedAt: laterUpdate)

        let result = GrowthCurve.deduplicatedByDay([older, newer])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.heightCm, 71.5)
    }

    func test_deduplicatedByDay_differentDays_keepsBoth() {
        let first = record(measuredOn: "2026-05-20", height: 70.0)
        let second = record(measuredOn: "2026-06-20", height: 71.0)

        let result = GrowthCurve.deduplicatedByDay([first, second])

        XCTAssertEqual(result.count, 2)
    }

    // MARK: - 缺值處理（曲線點）

    /// 13mo 缺身高，身高曲線應該只有 5 個點（1/4/7/10/16mo），不是 6 個補 0 或補 nil 的點。
    func test_curvePoints_skipsRecordsMissingThatMetric() {
        let birthday = date("2025-04-20")
        let records = [
            record(measuredOn: "2025-05-20", height: 52.0),
            record(measuredOn: "2025-08-20", height: 62.5),
            record(measuredOn: "2025-11-20", height: 68.5),
            record(measuredOn: "2026-02-20", height: 73.0),
            record(measuredOn: "2026-05-20", head: 44.4),
            record(measuredOn: "2026-08-20", height: 78.5)
        ]

        let points = GrowthCurve.curvePoints(for: .height, records: records, birthday: birthday)

        XCTAssertEqual(points.map(\.ageMonths), [1, 4, 7, 10, 16])
        XCTAssertEqual(points.map(\.value), [52.0, 62.5, 68.5, 73.0, 78.5])
    }

    // MARK: - 最新值與較上次差 ▲▼

    /// 逐字對齊 Notes `db1ET`：身高最新 16mo 78.5，「上一筆有值」是 10mo 73.0（13mo 缺身高）
    /// ——delta 是 +5.5，不是跟陣列相鄰的 13mo 比。
    func test_latestValue_skipsMissingRecordsWhenComputingDelta() {
        let records = [
            record(measuredOn: "2025-05-20", height: 52.0),
            record(measuredOn: "2025-08-20", height: 62.5),
            record(measuredOn: "2025-11-20", height: 68.5),
            record(measuredOn: "2026-02-20", height: 73.0),
            record(measuredOn: "2026-05-20", head: 44.4),
            record(measuredOn: "2026-08-20", height: 78.5)
        ]

        let latest = GrowthCurve.latestValue(for: .height, records: records)

        XCTAssertEqual(latest?.value, 78.5)
        XCTAssertEqual(latest?.delta ?? .nan, 5.5, accuracy: 0.0001)
    }

    /// 頭圍：16mo 45.0，上一筆有值是 13mo 44.4（相鄰、都有值）——delta +0.6。
    func test_latestValue_headCircumference_adjacentDelta() {
        let records = [
            record(measuredOn: "2026-05-20", head: 44.4),
            record(measuredOn: "2026-08-20", head: 45.0)
        ]

        let latest = GrowthCurve.latestValue(for: .head, records: records)

        XCTAssertEqual(latest?.delta ?? .nan, 0.6, accuracy: 0.0001)
    }

    /// 只有一筆記錄——沒有「上一筆」可比較，delta 必須是 nil，不能被誤算成 0 或整個崩潰。
    func test_latestValue_singleRecord_deltaIsNil() {
        let records = [record(measuredOn: "2026-08-20", weight: 9.6)]

        let latest = GrowthCurve.latestValue(for: .weight, records: records)

        XCTAssertEqual(latest?.value, 9.6)
        XCTAssertNil(latest?.delta)
    }

    /// 負向差值（這次比上次輕／矮／小）——`formattedDelta` 用全形減號，不是連字號。
    func test_latestValue_negativeDelta_formatsWithFullWidthMinus() {
        let records = [
            record(measuredOn: "2026-05-20", weight: 9.0),
            record(measuredOn: "2026-08-20", weight: 8.7)
        ]

        let latest = GrowthCurve.latestValue(for: .weight, records: records)

        XCTAssertEqual(latest?.delta ?? .nan, -0.3, accuracy: 0.0001)
        XCTAssertEqual(GrowthMetric.weight.formattedDelta(latest!.delta!), "\u{2212}0.3 kg")
    }

    func test_latestValue_noRecordsForMetric_returnsNil() {
        let records = [record(measuredOn: "2026-08-20", height: 78.5)]

        XCTAssertNil(GrowthCurve.latestValue(for: .weight, records: records))
    }

    // MARK: - Y 軸格線

    func test_gridlines_emptyValues_returnsEmpty() {
        XCTAssertEqual(GrowthCurve.gridlines(values: []), [])
    }

    func test_gridlines_returnsFourAscendingValuesSpanningPaddedRange() {
        let lines = GrowthCurve.gridlines(values: [52.0, 62.5, 68.5, 73.0, 78.5])

        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines, lines.sorted())
        XCTAssertLessThan(lines.first!, 52.0)
        XCTAssertGreaterThan(lines.last!, 78.5)
    }

    // MARK: - X 軸刻度密度

    func test_xAxisLabelIndices_normalDensity_showsAllPoints() {
        XCTAssertEqual(GrowthCurve.xAxisLabelIndices(pointCount: 6, isCompactDensity: false), [0, 1, 2, 3, 4, 5])
    }

    /// 逐字對齊 Notes `pQzHW`：6 個資料點（月齡 1/4/7/10/13/16）在 AX3 只標 1/7/16——索引 0/2/5。
    func test_xAxisLabelIndices_ax3Density_sixPoints_showsFirstAndLastWithEveryOther() {
        XCTAssertEqual(GrowthCurve.xAxisLabelIndices(pointCount: 6, isCompactDensity: true), [0, 2, 5])
    }

    func test_xAxisLabelIndices_ax3Density_twoOrFewerPoints_showsAll() {
        XCTAssertEqual(GrowthCurve.xAxisLabelIndices(pointCount: 2, isCompactDensity: true), [0, 1])
        XCTAssertEqual(GrowthCurve.xAxisLabelIndices(pointCount: 0, isCompactDensity: true), [])
    }
}

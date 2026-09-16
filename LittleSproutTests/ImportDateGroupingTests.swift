@testable import LittleSprout
import XCTest

/// LS-303 範圍 2／驗收：分組（含跨日、無日期）、N 隨略過即時對應、上限 200——同
/// `TimelineDayGroupingTests` 既有慣例，UTC 曆法避開跑測試機器本地時區影響 `startOfDay`。
final class ImportDateGroupingTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ isoString: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)!
    }

    private func asset(
        _ localIdentifier: String, creationDate: Date?
    ) -> ImportDateGrouping.PickedAsset {
        .init(localIdentifier: localIdentifier, creationDate: creationDate)
    }

    // MARK: - 分組：跨日

    func test_group_sameDayAssets_endUpInOneGroup() {
        let assets = [
            asset("a", creationDate: date("2026-09-10T20:00:00Z")),
            asset("b", creationDate: date("2026-09-10T09:00:00Z"))
        ]
        let groups = ImportDateGrouping.group(assets, calendar: utcCalendar)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].assetLocalIdentifiers, ["a", "b"])
        XCTAssertFalse(groups[0].isDateUnknown)
    }

    func test_group_differentDays_produceSeparateGroupsSortedDescending() {
        let assets = [
            asset("old", creationDate: date("2026-08-22T12:00:00Z")),
            asset("mid", creationDate: date("2026-09-08T12:00:00Z")),
            asset("new", creationDate: date("2026-09-10T12:00:00Z"))
        ]
        let groups = ImportDateGrouping.group(assets, calendar: utcCalendar)
        XCTAssertEqual(groups.map(\.assetLocalIdentifiers), [["new"], ["mid"], ["old"]])
        XCTAssertEqual(groups.map(\.isDateUnknown), [false, false, false])
    }

    // MARK: - 分組：無日期

    func test_group_assetsWithoutCreationDate_fallToUnknownDateGroupDefaultingToday() {
        let today = date("2026-09-15T08:00:00Z")
        let assets = [
            asset("known", creationDate: date("2026-09-10T12:00:00Z")),
            asset("noDate1", creationDate: nil),
            asset("noDate2", creationDate: nil)
        ]
        let groups = ImportDateGrouping.group(assets, calendar: utcCalendar, today: today)
        XCTAssertEqual(groups.count, 2)
        let unknownGroup = try? XCTUnwrap(groups.last)
        XCTAssertEqual(unknownGroup?.isDateUnknown, true)
        XCTAssertEqual(unknownGroup?.id, ImportDateGrouping.unknownDateGroupID)
        XCTAssertEqual(unknownGroup?.assetLocalIdentifiers, ["noDate1", "noDate2"])
        XCTAssertEqual(unknownGroup?.anchorDate, utcCalendar.startOfDay(for: today))
    }

    func test_group_allAssetsWithoutCreationDate_producesSingleUnknownGroup() {
        let assets = [asset("a", creationDate: nil), asset("b", creationDate: nil)]
        let groups = ImportDateGrouping.group(assets, calendar: utcCalendar)
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isDateUnknown)
    }

    func test_group_emptyInput_producesNoGroups() {
        XCTAssertTrue(ImportDateGrouping.group([], calendar: utcCalendar).isEmpty)
    }

    // MARK: - 上限 200

    func test_group_twoHundredAssets_preservesFullCountAcrossGroups() {
        let assets = (0..<200).map { index in
            asset("id-\(index)", creationDate: date("2026-09-01T00:00:00Z").addingTimeInterval(Double(index) * 86400))
        }
        let groups = ImportDateGrouping.group(assets, calendar: utcCalendar)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.assetLocalIdentifiers.count }, 200)
        XCTAssertEqual(groups.count, 200) // 每天各一張，200 個不同日期 → 200 群
    }

    // MARK: - N 隨略過即時對應（ImportPlan.pendingAssetCount）

    func test_pendingAssetCount_excludesSkippedGroups_andUpdatesImmediately() {
        let assets = [
            asset("a", creationDate: date("2026-09-10T12:00:00Z")),
            asset("b", creationDate: date("2026-09-10T13:00:00Z")),
            asset("c", creationDate: date("2026-09-08T12:00:00Z")),
            asset("d", creationDate: date("2026-09-08T13:00:00Z")),
            asset("e", creationDate: date("2026-09-08T14:00:00Z"))
        ]
        var plan = ImportPlan(groups: ImportDateGrouping.group(assets, calendar: utcCalendar))
        XCTAssertEqual(plan.totalAssetCount, 5)
        XCTAssertEqual(plan.pendingAssetCount, 5)

        // 略過其中一群（3 張）——主鈕 N 應立即扣掉這一群。
        plan.groups[1].isSkipped = true
        XCTAssertEqual(plan.pendingAssetCount, 2)
        XCTAssertEqual(plan.totalAssetCount, 5, "totalAssetCount 是頂部摘要用的原始選取總數，不受略過影響")

        // 取消略過——N 應該即時加回來。
        plan.groups[1].isSkipped = false
        XCTAssertEqual(plan.pendingAssetCount, 5)
    }

    func test_pendingAssetCount_allGroupsSkipped_isZero() {
        var plan = ImportPlan(groups: [
            ImportPlan.Group(
                id: "2026-09-10", anchorDate: date("2026-09-10T00:00:00Z"), isDateUnknown: false,
                assetLocalIdentifiers: ["a", "b"]
            )
        ])
        plan.groups[0].isSkipped = true
        XCTAssertEqual(plan.pendingAssetCount, 0)
    }

    // MARK: - 日期格式四型 C4a①②

    func test_groupHeaderLabel_formatsAsMonthDayWithoutWeekday() {
        let label = ImportDateFormatting.groupHeaderLabel(for: date("2026-09-10T12:00:00Z"), calendar: utcCalendar)
        XCTAssertEqual(label, "9月10日")
    }

    func test_unknownDateGroupLabel_formatsAsTodayWithParentheticalMonthDay() {
        let label = ImportDateFormatting.unknownDateGroupLabel(
            anchorDate: date("2026-09-15T00:00:00Z"), calendar: utcCalendar
        )
        XCTAssertEqual(label, "今天（9/15）")
    }
}

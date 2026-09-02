@testable import LittleSprout
import XCTest

final class TimelineDayGroupingTests: XCTestCase {
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

    private func entry(kind: FeedKind = .media, refId: UUID = UUID(), occurredAt: Date) -> TimelineEntry {
        TimelineEntry(kind: kind, refId: refId, occurredAt: occurredAt, childIds: [], content: nil)
    }

    func test_group_sameDayEntries_endUpInOneGroup() {
        let entries = [
            entry(occurredAt: date("2026-09-02T20:00:00Z")),
            entry(occurredAt: date("2026-09-02T10:00:00Z")),
            entry(occurredAt: date("2026-09-02T01:00:00Z"))
        ]
        let groups = TimelineDayGrouping.group(entries, calendar: utcCalendar)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].entries.count, 3)
    }

    func test_group_differentDays_produceSeparateGroupsInOriginalOrder() {
        // 已排序（occurred_at desc）輸入：跨日補記（「補記昨天」）落在正確位置——分組只切邊界，
        // 不重排。
        let entries = [
            entry(occurredAt: date("2026-09-02T09:00:00Z")),
            entry(occurredAt: date("2026-09-01T22:00:00Z")),
            entry(occurredAt: date("2026-09-01T08:00:00Z")),
            entry(occurredAt: date("2026-08-30T12:00:00Z")) // 補記：跳過 8/31，落在自己那天
        ]
        let groups = TimelineDayGrouping.group(entries, calendar: utcCalendar)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].entries.count, 1)
        XCTAssertEqual(groups[1].entries.count, 2)
        XCTAssertEqual(groups[2].entries.count, 1)
    }

    func test_group_nonConsecutiveSameDayEntries_doNotMerge() {
        // 已排序輸入不應出現「同一天被切成兩組又重新合併」的情況，但若給定順序本身不是
        // 依日期排序（理論上 get_family_timeline 不會這樣給），分組仍應忠實反映輸入順序、
        // 不強行合併非相鄰的同日項目——這裡驗證「只看相鄰」這個邊界行為本身是穩定的。
        let entries = [
            entry(occurredAt: date("2026-09-02T09:00:00Z")),
            entry(occurredAt: date("2026-09-01T09:00:00Z")),
            entry(occurredAt: date("2026-09-02T08:00:00Z"))
        ]
        let groups = TimelineDayGrouping.group(entries, calendar: utcCalendar)
        XCTAssertEqual(groups.count, 3)
    }

    func test_group_emptyInput_producesNoGroups() {
        XCTAssertTrue(TimelineDayGrouping.group([], calendar: utcCalendar).isEmpty)
    }

    func test_group_dayIsIdentifiable() {
        let entries = [entry(occurredAt: date("2026-09-02T09:00:00Z"))]
        let groups = TimelineDayGrouping.group(entries, calendar: utcCalendar)
        XCTAssertEqual(groups[0].id, groups[0].day)
    }
}

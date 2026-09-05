import Foundation
@testable import LittleSprout
import XCTest

/// LS-167：純函式覆蓋——分群與排序規則（`UploadQueueGrouping`）、`AppError`→
/// `UploadFailureReason` 對應、時間戳文案。`UploadQueueStore` 的並發／重試行為另外拆到
/// `UploadQueueStoreTests`（需要 async／stub，理由同 `DiaryComposerStoreTests` 系列的拆檔
/// 慣例）。
final class UploadQueueModelsTests: XCTestCase {
    // MARK: - UploadFailureReason.from(_:)

    func test_from_network_isNetwork() {
        XCTAssertEqual(UploadFailureReason.from(.network(message: "offline")), .network)
    }

    func test_from_rejectedWithLS002_isQuota() {
        let error = AppError.rejected(message: "額度已滿", code: LSErrorCode.storageQuotaExceeded.rawValue)
        XCTAssertEqual(UploadFailureReason.from(error), .quota)
    }

    func test_from_rejectedWithOtherCode_fallsBackToServer() {
        // 已知不完美之處（見 `UploadFailureReason.from` 文件註解）：非 LS002 的 rejected
        // （例如帳號停權 LS052）目前落在同一個「伺服器忙碌」桶，不是設計稿涵蓋的情境。
        let error = AppError.rejected(message: "帳號已停權", code: LSErrorCode.accountSuspended.rawValue)
        XCTAssertEqual(UploadFailureReason.from(error), .server)
    }

    func test_from_server_isServer() {
        XCTAssertEqual(UploadFailureReason.from(.server(message: "500", code: nil)), .server)
    }

    func test_from_retryableSystem_fallsBackToServer() {
        XCTAssertEqual(UploadFailureReason.from(.retryableSystem(message: "重試", code: nil)), .server)
    }

    func test_from_validationRetryable_fallsBackToServer() {
        // 例如 `MediaUploadService.mapUploadError` 的 Storage 413 payload-too-large。
        let error = AppError.validationRetryable(message: "413", code: DiaryMediaErrorCode.payloadTooLarge)
        XCTAssertEqual(UploadFailureReason.from(error), .server)
    }

    func test_quota_isNotRetryable_andShowsStorageLink() {
        XCTAssertFalse(UploadFailureReason.quota.isRetryable)
        XCTAssertTrue(UploadFailureReason.quota.showsQuotaLink)
    }

    func test_networkAndServer_areRetryable_andDoNotShowStorageLink() {
        XCTAssertTrue(UploadFailureReason.network.isRetryable)
        XCTAssertTrue(UploadFailureReason.server.isRetryable)
        XCTAssertFalse(UploadFailureReason.network.showsQuotaLink)
        XCTAssertFalse(UploadFailureReason.server.showsQuotaLink)
    }

    // MARK: - UploadQueueGrouping：分群

    func test_sections_splitsByStateIntoThreeGroups() {
        let now = Date()
        let rows = [
            UploadQueueRow(id: UUID(), enqueuedAt: now, state: .failed(.network)),
            UploadQueueRow(id: UUID(), enqueuedAt: now, state: .waiting),
            UploadQueueRow(id: UUID(), enqueuedAt: now, state: .uploading(progress: nil)),
            UploadQueueRow(id: UUID(), enqueuedAt: now, state: .completed)
        ]

        let sections = UploadQueueGrouping.sections(for: rows)

        XCTAssertEqual(sections.map(\.kind), [.failed, .inProgress, .completed])
        XCTAssertEqual(sections[0].rows.count, 1)
        XCTAssertEqual(sections[1].rows.count, 2, "waiting 與 uploading 都算 In Progress")
        XCTAssertEqual(sections[2].rows.count, 1)
    }

    func test_sections_emptyGroupsAreOmitted() {
        let rows = [UploadQueueRow(id: UUID(), enqueuedAt: Date(), state: .completed)]

        let sections = UploadQueueGrouping.sections(for: rows)

        XCTAssertEqual(sections.map(\.kind), [.completed], "沒有內容的群不該出現在結果裡")
    }

    // MARK: - UploadQueueGrouping：排序

    func test_inProgressAndCompleted_sortNewestFirst() {
        let now = Date()
        let older = UploadQueueRow(id: UUID(), enqueuedAt: now.addingTimeInterval(-120), state: .waiting)
        let newer = UploadQueueRow(
            id: UUID(), enqueuedAt: now.addingTimeInterval(-60), state: .uploading(progress: nil)
        )

        let sections = UploadQueueGrouping.sections(for: [older, newer])

        XCTAssertEqual(sections[0].rows.map(\.id), [newer.id, older.id])
    }

    func test_failedGroup_pinsQuotaFirstRegardlessOfTimestamp() {
        // `design/littlesprout.pen` Handoff Notes `pUvzU`／INFO-N3：可處理性優先於時間序——
        // LS002 固定排最前，即使它是三筆裡最舊的一筆（票文驗收條件「LS002 容量已滿列最前」）。
        let now = Date()
        let quota = UploadQueueRow(id: UUID(), enqueuedAt: now.addingTimeInterval(-600), state: .failed(.quota))
        let networkNewer = UploadQueueRow(id: UUID(), enqueuedAt: now.addingTimeInterval(-60), state: .failed(.network))
        let serverOlder = UploadQueueRow(id: UUID(), enqueuedAt: now.addingTimeInterval(-300), state: .failed(.server))

        let sections = UploadQueueGrouping.sections(for: [networkNewer, quota, serverOlder])

        XCTAssertEqual(
            sections[0].rows.map(\.id), [quota.id, networkNewer.id, serverOlder.id],
            "LS002 置頂；其餘依時間新到舊排在其後"
        )
    }

    func test_failedGroup_multipleQuotaItems_sortAmongThemselvesNewestFirst_beforeOthers() {
        let now = Date()
        let quotaOld = UploadQueueRow(id: UUID(), enqueuedAt: now.addingTimeInterval(-600), state: .failed(.quota))
        let quotaNew = UploadQueueRow(id: UUID(), enqueuedAt: now.addingTimeInterval(-60), state: .failed(.quota))
        let network = UploadQueueRow(id: UUID(), enqueuedAt: now, state: .failed(.network))

        let sections = UploadQueueGrouping.sections(for: [quotaOld, network, quotaNew])

        XCTAssertEqual(sections[0].rows.map(\.id), [quotaNew.id, quotaOld.id, network.id])
    }

    // MARK: - UploadQueueTimestampFormat

    func test_timestampFormat_sameDay_prefixesToday() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 18, minute: 0))!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 14, minute: 29))!

        let text = UploadQueueTimestampFormat.string(for: date, now: now, calendar: calendar)

        XCTAssertEqual(text, "今天 14:29")
    }

    func test_timestampFormat_previousDay_prefixesYesterday() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 9, minute: 0))!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 22, minute: 5))!

        let text = UploadQueueTimestampFormat.string(for: date, now: now, calendar: calendar)

        XCTAssertEqual(text, "昨天 22:05")
    }

    func test_timestampFormat_olderDate_usesMonthDay() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 9, minute: 0))!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 8, minute: 3))!

        let text = UploadQueueTimestampFormat.string(for: date, now: now, calendar: calendar)

        XCTAssertEqual(text, "9/1 08:03")
    }
}

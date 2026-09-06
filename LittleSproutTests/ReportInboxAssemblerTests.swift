import Foundation
@testable import LittleSprout
import XCTest

/// `ReportInboxAssembler`（LS-189 R2，merge-review R1 m1／B3）：釘住「依 targetType 分組批次
/// 查」取代「逐筆序列 await」——N 筆檢舉、K 種型別只該觸發 K 次 `fetchReportSnippets`，不是 N
/// 次。用 `StubSafetyAPIClient` 記錄呼叫次數與參數，不需要真的起 View／模擬器。
final class ReportInboxAssemblerTests: XCTestCase {
    private func makeReport(
        id: UUID = UUID(), targetType: ContentTargetType, targetID: UUID = UUID()
    ) -> ContentReportRecord {
        ContentReportRecord(
            id: id, targetType: targetType, targetID: targetID, reporterID: UUID(), reason: "spam",
            status: "pending", createdAt: Date()
        )
    }

    /// Mutation guard：若把 `assembleItems` 改回逐筆 `for report in reports { await
    /// fetchReportSnippet(...) }`，`snippetsCalls.count` 會變成 5（每筆一次），這支測試會紅。
    func test_assembleItems_batchesByTargetType_notPerReport() async {
        let diaryIDs = [UUID(), UUID(), UUID()]
        let commentIDs = [UUID(), UUID()]
        let reports = diaryIDs.map { makeReport(targetType: .diary, targetID: $0) }
            + commentIDs.map { makeReport(targetType: .comment, targetID: $0) }
        let stub = StubSafetyAPIClient(snippetsByType: [
            .diary: Dictionary(uniqueKeysWithValues: diaryIDs.map { ($0, "日記內容") }),
            .comment: Dictionary(uniqueKeysWithValues: commentIDs.map { ($0, "留言內容") })
        ])

        let items = await ReportInboxAssembler.assembleItems(reports, safetyAPIClient: stub)

        XCTAssertEqual(stub.snippetsCalls.count, 2, "5 筆檢舉、2 種型別應該只觸發 2 次批次查詢，不是 5 次")
        let calledTypes = Set(stub.snippetsCalls.map(\.targetType))
        XCTAssertEqual(calledTypes, [.diary, .comment])
        XCTAssertEqual(items.count, 5)
        XCTAssertTrue(items.allSatisfy { $0.snippet == "日記內容" || $0.snippet == "留言內容" })
    }

    /// `media` 沒有文字內容——不該觸發任何查詢，一律顯示通用標籤。
    func test_assembleItems_media_skipsNetworkCall_usesGenericLabel() async {
        let report = makeReport(targetType: .media)
        let stub = StubSafetyAPIClient()

        let items = await ReportInboxAssembler.assembleItems([report], safetyAPIClient: stub)

        XCTAssertTrue(stub.snippetsCalls.isEmpty, "media 型別不該觸發任何批次查詢")
        XCTAssertEqual(items.first?.snippet, "一張照片或影片")
    }

    /// 查得到型別但查不到這個 id（內容已被硬刪，理論上不會發生，軟刪列仍在）——顯示兜底文案。
    func test_assembleItems_snippetMissing_fallsBackToRemovedText() async {
        let report = makeReport(targetType: .diary)
        let stub = StubSafetyAPIClient(snippetsByType: [.diary: [:]])

        let items = await ReportInboxAssembler.assembleItems([report], safetyAPIClient: stub)

        XCTAssertEqual(items.first?.snippet, "這則內容已經被移除")
    }
}

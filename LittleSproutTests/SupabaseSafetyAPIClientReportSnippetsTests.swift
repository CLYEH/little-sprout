import Foundation
@testable import LittleSprout
import os
import XCTest

/// `SupabaseSafetyAPIClient.fetchReportSnippets`（LS-189 R2，merge-review R1 m1）。跟
/// `SupabaseSafetyAPIClientTests` 是同一個測試對象，拆成獨立檔案純粹是為了 SwiftLint
/// `type_body_length`（同 `TimelineStoreDeleteDiaryTests.swift` 的既有拆檔理由與寫法）。
extension SupabaseSafetyAPIClientTests {
    /// 兩個 id 一次查回——同一次請求（`.in("id", values:)`），不是兩次來回，直接證明 N+1 修正。
    func test_fetchReportSnippets_diary_batchesMultipleIDsInOneRequest() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let requestCount = OSAllocatedUnfairLock(initialState: 0)
        let client = TestSupabaseClient.make { request in
            requestCount.withLock { $0 += 1 }
            XCTAssertEqual(request.url?.path, "/rest/v1/diaries")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("select=id%2Cbody") || query.contains("select=id,body"), query)
            XCTAssertTrue(query.contains("id=in."), query)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"id":"\(firstID.uuidString)","body":"今天在溜滑梯上玩得好開心。"},
             {"id":"\(secondID.uuidString)","body":"下雨天在家畫畫。"}]
            """.utf8))
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        let snippets = try await apiClient.fetchReportSnippets(targetType: .diary, targetIDs: [firstID, secondID])
        XCTAssertEqual(requestCount.withLock { $0 }, 1, "兩個 id 應該只發一次請求，不是逐筆兩次")
        XCTAssertEqual(snippets[firstID], "今天在溜滑梯上玩得好開心。")
        XCTAssertEqual(snippets[secondID], "下雨天在家畫畫。")
    }

    /// `media` 沒有文字內容欄位——不應該發任何網路請求，直接回空字典。
    func test_fetchReportSnippets_media_returnsEmptyWithoutNetworkCall() async throws {
        let client = TestSupabaseClient.make { _ in
            XCTFail("media 型別不該發任何網路請求")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        let snippets = try await apiClient.fetchReportSnippets(targetType: .media, targetIDs: [UUID()])
        XCTAssertTrue(snippets.isEmpty)
    }

    /// 空 id 陣列——不應該發任何網路請求（同 `SupabaseTimelineAPIClient.fetchDiaries` 既有慣例）。
    func test_fetchReportSnippets_emptyIDs_returnsEmptyWithoutNetworkCall() async throws {
        let client = TestSupabaseClient.make { _ in
            XCTFail("空 id 陣列不該發任何網路請求")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        let snippets = try await apiClient.fetchReportSnippets(targetType: .comment, targetIDs: [])
        XCTAssertTrue(snippets.isEmpty)
    }

    func test_fetchReportSnippets_targetGone_omittedFromResult() async throws {
        // 內容已被硬刪（理論上不會發生，軟刪列仍在）——0 列不是錯誤，呼叫端顯示兜底文案。
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        let snippets = try await apiClient.fetchReportSnippets(targetType: .comment, targetIDs: [UUID()])
        XCTAssertTrue(snippets.isEmpty)
    }
}

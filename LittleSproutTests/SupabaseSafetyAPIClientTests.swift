import Foundation
@testable import LittleSprout
import XCTest

/// `SupabaseSafetyAPIClient` 對五個查詢面（`fetchContentAuthor`／`reportContent`／
/// `blockUser`／`unblockUser`／`removeContentAsOwner`／`listBlockedUsers`／
/// `listPendingReports`／`markReportResolved`／`fetchReportSnippets`）的編碼與錯誤映射。用
/// `MockURLProtocol` 攔截請求（不打真網路），同 `SupabaseCommentAPIClientTests`／
/// `SupabaseFamilyAPIClientProfileTests` 的既有模式。
final class SupabaseSafetyAPIClientTests: XCTestCase {
    private let familyID = UUID()
    private let targetID = UUID()
    private let authorID = UUID()
    private let blockedID = UUID()
    private let reportID = UUID()

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    // MARK: - fetchContentAuthor（四種目標型別各自查對應表的作者欄位）

    func test_fetchContentAuthor_diary_queriesDiariesAuthorID() async throws {
        let client = TestSupabaseClient.make { [targetID, authorID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/diaries")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("select=author_id"), query)
            XCTAssertTrue(query.contains("id=eq.\(targetID.uuidString)"), query)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"author_id":"\(authorID.uuidString)"}]
            """.utf8))
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        let result = try await apiClient.fetchContentAuthor(targetType: .diary, targetID: targetID)
        XCTAssertEqual(result, authorID)
    }

    func test_fetchContentAuthor_media_queriesMediaUploadedBy() async throws {
        let client = TestSupabaseClient.make { [targetID, authorID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/media")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("select=uploaded_by"), query)
            XCTAssertTrue(query.contains("id=eq.\(targetID.uuidString)"), query)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"uploaded_by":"\(authorID.uuidString)"}]
            """.utf8))
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        let result = try await apiClient.fetchContentAuthor(targetType: .media, targetID: targetID)
        XCTAssertEqual(result, authorID)
    }

    func test_fetchContentAuthor_authorSetNull_returnsNil() async throws {
        // 作者已離開家庭（profiles 列 on delete set null）——contentActions 依此視為「作者未知」。
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"author_id":null}]
            """.utf8))
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        let result = try await apiClient.fetchContentAuthor(targetType: .comment, targetID: targetID)
        XCTAssertNil(result)
    }

    // MARK: - reportContent

    func test_reportContent_sendsFamilyIDTargetTypeTargetIDAndReasonKey() async throws {
        let client = TestSupabaseClient.make { [familyID, targetID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/report_content")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_family_id"] as? String, familyID.uuidString)
            XCTAssertEqual(payload["p_target_type"] as? String, "comment")
            XCTAssertEqual(payload["p_target_id"] as? String, targetID.uuidString)
            // 送 ASCII key（`harassment`），不是中文顯示文字——Notes MN-7 契約。
            XCTAssertEqual(payload["p_reason"] as? String, "harassment")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("\"\(UUID().uuidString)\"".utf8))
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        try await apiClient.reportContent(
            familyID: familyID, targetType: .comment, targetID: targetID, reason: .harassment
        )
    }

    func test_reportContent_targetInDifferentFamily_mapsToRejectedWithLS026() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS026","message":"target 屬於別的家庭"}
            """.utf8))
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        do {
            try await apiClient.reportContent(
                familyID: familyID, targetType: .comment, targetID: targetID, reason: .other
            )
            XCTFail("LS026 應該要 throw")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("LS026 應映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "LS026")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    // MARK: - blockUser／unblockUser

    func test_blockUser_sendsFamilyIDAndBlockedID() async throws {
        let client = TestSupabaseClient.make { [familyID, blockedID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/block_user")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_family_id"] as? String, familyID.uuidString)
            XCTAssertEqual(payload["p_blocked_id"] as? String, blockedID.uuidString)
            return MockURLProtocol.StubResponse(statusCode: 204, body: Data())
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        try await apiClient.blockUser(familyID: familyID, blockedID: blockedID)
    }

    func test_blockUser_selfBlock_mapsToValidationRetryableWith23514() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"23514","message":"blocked_users_not_self"}
            """.utf8))
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        do {
            try await apiClient.blockUser(familyID: familyID, blockedID: blockedID)
            XCTFail("23514 應該要 throw")
        } catch let error as AppError {
            guard case .validationRetryable(_, let code) = error else {
                return XCTFail("23514 應映射為 .validationRetryable，實際是 \(error)")
            }
            XCTAssertEqual(code, "23514")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    func test_unblockUser_sendsFamilyIDAndBlockedID() async throws {
        let client = TestSupabaseClient.make { [familyID, blockedID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/unblock_user")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_family_id"] as? String, familyID.uuidString)
            XCTAssertEqual(payload["p_blocked_id"] as? String, blockedID.uuidString)
            return MockURLProtocol.StubResponse(statusCode: 204, body: Data())
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        try await apiClient.unblockUser(familyID: familyID, blockedID: blockedID)
    }

    // MARK: - removeContentAsOwner

    func test_removeContentAsOwner_sendsTargetTypeAndTargetID() async throws {
        let client = TestSupabaseClient.make { [targetID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/remove_content_as_owner")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_target_type"] as? String, "album")
            XCTAssertEqual(payload["p_target_id"] as? String, targetID.uuidString)
            return MockURLProtocol.StubResponse(statusCode: 204, body: Data())
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        try await apiClient.removeContentAsOwner(targetType: .album, targetID: targetID)
    }

    func test_removeContentAsOwner_notOwner_mapsToRejectedWith42501() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 401, body: Data("""
            {"code":"42501","message":"permission denied"}
            """.utf8))
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        do {
            try await apiClient.removeContentAsOwner(targetType: .album, targetID: targetID)
            XCTFail("42501 應該要 throw")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("42501 應映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "42501")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    // MARK: - listBlockedUsers／listPendingReports

    func test_listBlockedUsers_queriesBlockedUsersScopedToFamily() async throws {
        let client = TestSupabaseClient.make { [familyID, blockedID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/blocked_users")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("family_id=eq.\(familyID.uuidString)"), query)
            // LS-189 R2（merge-review R1 m1）：封鎖名單不該無限長，見 `SupabaseSafetyAPIClient
            // .listBlockedUsers` 文件註解。
            XCTAssertTrue(query.contains("limit=50"), query)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"blocked_id":"\(blockedID.uuidString)","created_at":"2026-09-01T00:00:00Z"}]
            """.utf8))
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        let result = try await apiClient.listBlockedUsers(familyID: familyID)
        XCTAssertEqual(result.map(\.blockedID), [blockedID])
    }

    func test_listPendingReports_filtersToPendingStatus() async throws {
        let client = TestSupabaseClient.make { [familyID, reportID, targetID, authorID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/content_reports")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("family_id=eq.\(familyID.uuidString)"), query)
            XCTAssertTrue(query.contains("status=eq.pending"), query)
            // LS-189 R2（merge-review R1 m1）：收件匣不該無限長，見 `SupabaseSafetyAPIClient
            // .listPendingReports` 文件註解。
            XCTAssertTrue(query.contains("limit=50"), query)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"id":"\(reportID.uuidString)","target_type":"comment","target_id":"\(targetID.uuidString)",
              "reporter_id":"\(authorID.uuidString)","reason":"spam","status":"pending",
              "created_at":"2026-09-01T00:00:00Z"}]
            """.utf8))
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        let result = try await apiClient.listPendingReports(familyID: familyID)
        XCTAssertEqual(result.map(\.id), [reportID])
        XCTAssertEqual(result.first?.targetType, .comment)
    }

    // MARK: - markReportResolved（同 `removeMember` 既有的「requireUpdatedRow」手法）

    func test_markReportResolved_updatesStatusToResolved() async throws {
        let client = TestSupabaseClient.make { [reportID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/content_reports")
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["status"] as? String, "resolved")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"id":"\(reportID.uuidString)"}]
            """.utf8))
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        try await apiClient.markReportResolved(reportID: reportID)
    }

    /// `content_reports` 的 UPDATE policy 是 owner-only 的 RLS USING 過濾——非 owner 呼叫時
    /// PostgREST 回 200＋`[]`（合法執行、匹配 0 列），SDK 不會 throw。這裡明確把「0 列受影響」
    /// 轉成錯誤，同 `SupabaseFamilyAPIClientProfileTests
    /// .test_removeMember_zeroRowsAffected_throwsRejected` 既有手法——不修這條防線的話，非
    /// owner 點「這則沒問題」會被 UI 誤判成功，檢舉其實還在 pending。
    func test_markReportResolved_zeroRowsAffected_throwsRejected() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseSafetyAPIClient(client: client)

        do {
            try await apiClient.markReportResolved(reportID: reportID)
            XCTFail("0 列受影響應該 throw，不是靜默成功")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("應該映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "no_rows_updated")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

}

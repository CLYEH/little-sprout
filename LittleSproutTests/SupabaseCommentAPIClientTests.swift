import Foundation
@testable import LittleSprout
import XCTest

/// `SupabaseCommentAPIClient` 對 `set_comment_deleted` RPC 的編碼與錯誤映射。用
/// `MockURLProtocol` 攔截請求（不打真網路），同 `SupabaseDiaryAPIClientTests` 的模式。
final class SupabaseCommentAPIClientTests: XCTestCase {
    private let commentID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func test_setCommentDeleted_softDelete_sendsCommentIDAndDeletedTrue() async throws {
        let client = TestSupabaseClient.make { [commentID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/set_comment_deleted")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_comment_id"] as? String, commentID.uuidString)
            XCTAssertEqual(payload["p_deleted"] as? Bool, true)
            return MockURLProtocol.StubResponse(statusCode: 204, body: Data())
        }
        let apiClient = SupabaseCommentAPIClient(client: client)

        try await apiClient.setCommentDeleted(commentID: commentID, deleted: true)
    }

    func test_setCommentDeleted_commentNotFound_mapsToRejectedWithLS024() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS024","message":"留言不存在"}
            """.utf8))
        }
        let apiClient = SupabaseCommentAPIClient(client: client)

        do {
            try await apiClient.setCommentDeleted(commentID: commentID, deleted: true)
            XCTFail("LS024 應該要 throw")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("LS024 應映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "LS024")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    // MARK: - LS-218：listComments

    private let familyID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    private let targetID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    func test_listComments_firstPage_omitsCursorParams_decodesRows() async throws {
        let client = TestSupabaseClient.make { [familyID, targetID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/list_comments")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_family_id"] as? String, familyID.uuidString)
            XCTAssertEqual(payload["p_target_type"] as? String, "diary")
            XCTAssertEqual(payload["p_target_id"] as? String, targetID.uuidString)
            // 第一頁不帶游標——合成 Encodable 對 nil Optional 用 encodeIfPresent 整個省略該 key。
            XCTAssertNil(payload["p_cursor_created_at"], "第一頁不應帶 p_cursor_created_at")
            XCTAssertNil(payload["p_cursor_id"], "第一頁不應帶 p_cursor_id")
            XCTAssertEqual(payload["p_limit"] as? Int, 20)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"id":"11111111-1111-1111-1111-111111111111","author_id":"22222222-2222-2222-2222-222222222222",
              "author_display_name":"陳志明","author_avatar_url":null,"body":"好可愛喔！",
              "created_at":"2026-09-12T10:00:00.000Z"}]
            """.utf8))
        }
        let apiClient = SupabaseCommentAPIClient(client: client)

        let rows = try await apiClient.listComments(
            familyID: familyID, targetType: "diary", targetID: targetID, cursor: nil, limit: 20
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].authorDisplayName, "陳志明")
        XCTAssertEqual(rows[0].body, "好可愛喔！")
    }

    func test_listComments_loadEarlier_sendsCursorParams() async throws {
        let cursorID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let cursorDate = Date(timeIntervalSince1970: 1_757_000_000)
        let client = TestSupabaseClient.make { [cursorID] request in
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_cursor_id"] as? String, cursorID.uuidString)
            XCTAssertNotNil(payload["p_cursor_created_at"], "載入更早應帶上游標時間戳")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseCommentAPIClient(client: client)

        _ = try await apiClient.listComments(
            familyID: familyID, targetType: "diary", targetID: targetID,
            cursor: CommentsCursor(createdAt: cursorDate, id: cursorID), limit: 20
        )
    }

    /// `CommentsCursor` 把 `(createdAt, id)` 綁成一組，呼叫端已經不可能只傳半個游標——這裡改
    /// 驗證「伺服器真的回 `LS022`（例如未來某個繞過 `CommentsCursor` 的呼叫路徑、或伺服器端
    /// 邏輯本身的邊界情況）時，`AppError.map` 仍正確歸類」，不是驗證我們自己會不會送出半游標
    /// （型別系統已經排除這個可能性）。
    func test_listComments_serverRejectsWithLS022_mapsToRejected() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS022","message":"游標參數只給了一半"}
            """.utf8))
        }
        let apiClient = SupabaseCommentAPIClient(client: client)

        do {
            _ = try await apiClient.listComments(
                familyID: familyID, targetType: "diary", targetID: targetID,
                cursor: CommentsCursor(createdAt: Date(), id: UUID()), limit: 20
            )
            XCTFail("LS022 應該要 throw")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("LS022 應映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "LS022")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    // MARK: - LS-218：createComment

    func test_createComment_sendsParams_returnsNewID() async throws {
        let newID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let client = TestSupabaseClient.make { [familyID, targetID, newID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/create_comment")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_family_id"] as? String, familyID.uuidString)
            XCTAssertEqual(payload["p_target_type"] as? String, "album")
            XCTAssertEqual(payload["p_target_id"] as? String, targetID.uuidString)
            XCTAssertEqual(payload["p_body"] as? String, "太可愛了")
            return MockURLProtocol.StubResponse(
                statusCode: 200, body: Data("\"\(newID.uuidString)\"".utf8)
            )
        }
        let apiClient = SupabaseCommentAPIClient(client: client)

        let returnedID = try await apiClient.createComment(
            familyID: familyID, targetType: "album", targetID: targetID, body: "太可愛了"
        )

        XCTAssertEqual(returnedID, newID)
    }

    func test_createComment_targetInAnotherFamily_mapsToRejectedWithLS026() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS026","message":"target 屬於別的家庭"}
            """.utf8))
        }
        let apiClient = SupabaseCommentAPIClient(client: client)

        do {
            _ = try await apiClient.createComment(
                familyID: familyID, targetType: "diary", targetID: targetID, body: "留言"
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
}

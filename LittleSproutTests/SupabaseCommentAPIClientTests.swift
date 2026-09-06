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
}

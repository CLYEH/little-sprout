import Foundation
@testable import LittleSprout
import XCTest

/// `SupabaseFamilyAPIClient` 的加入審核流程（request_join／approve_join／list_join_requests／
/// get_my_join_request）。家庭建立/更新的測試在 `SupabaseFamilyAPIClientTests`——純粹是
/// SwiftLint `type_body_length`（250 行）撞到才拆兩個檔，兩者共用同一份 Support。
final class SupabaseFamilyAPIClientJoinTests: XCTestCase {
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    override func tearDown() {
        // 見 SupabaseAuthServiceTests 同名 tearDown 的說明：MockURLProtocol 的 handler
        // 是全域 static，測試之間必須清乾淨（LS-49 PR #63 review F9）。
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func test_requestJoin_pending_decodesOutcome() async throws {
        let requestID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let client = TestSupabaseClient.make { [familyID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/request_join")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {"status":"pending","request_id":"\(requestID.uuidString)","family_id":"\(familyID.uuidString)"}
            """.utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let outcome = try await apiClient.requestJoin(code: "ABCD1234")

        guard case .pending(let decodedRequestID, let decodedFamilyID) = outcome else {
            return XCTFail("應該解成 .pending，實際是 \(outcome)")
        }
        XCTAssertEqual(decodedRequestID, requestID)
        XCTAssertEqual(decodedFamilyID, familyID)
    }

    func test_requestJoin_joined_decodesOutcome() async throws {
        let client = TestSupabaseClient.make { [familyID] _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {"status":"joined","request_id":null,"family_id":"\(familyID.uuidString)"}
            """.utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let outcome = try await apiClient.requestJoin(code: "ABCD1234")

        guard case .joined(let decodedFamilyID) = outcome else {
            return XCTFail("應該解成 .joined，實際是 \(outcome)")
        }
        XCTAssertEqual(decodedFamilyID, familyID)
    }

    func test_requestJoin_invalidCode_mapsToValidationRetryable() async {
        let client = TestSupabaseClient.make { _ in
            // LS010：邀請碼不存在。
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS010","message":"邀請碼不存在"}
            """.utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        do {
            _ = try await apiClient.requestJoin(code: "WRONGCODE")
            XCTFail("應該要 throw")
        } catch let error as AppError {
            guard case .validationRetryable(_, let code) = error else {
                return XCTFail("LS010 應映射為 .validationRetryable，實際是 \(error)")
            }
            XCTAssertEqual(code, "LS010")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    func test_approveJoin_success_doesNotThrow() async throws {
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/approve_join")
            return MockURLProtocol.StubResponse(statusCode: 204)
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        try await apiClient.approveJoin(requestID: UUID())
    }

    func test_listJoinRequests_decodesArray() async throws {
        let client = TestSupabaseClient.make { [familyID, userID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/list_join_requests")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "request_id": "\(UUID().uuidString)",
              "family_id": "\(familyID.uuidString)",
              "applicant_id": "\(userID.uuidString)",
              "display_name": "阿公",
              "avatar_url": null,
              "role": "member",
              "created_at": "2026-08-24T00:00:00Z"
            }]
            """.utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let requests = try await apiClient.listJoinRequests()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].displayName, "阿公")
        XCTAssertEqual(requests[0].role, .member)
    }

    func test_myJoinRequest_pendingResult_decodesStatus() async throws {
        let client = TestSupabaseClient.make { [familyID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/get_my_join_request")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "request_id": "\(UUID().uuidString)",
              "family_id": "\(familyID.uuidString)",
              "family_name": "葉家",
              "status": "pending",
              "created_at": "2026-08-24T00:00:00Z",
              "resolved_at": null
            }]
            """.utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let result = try await apiClient.myJoinRequest()

        XCTAssertEqual(result?.status, .pending)
        XCTAssertEqual(result?.familyName, "葉家")
    }

    func test_myJoinRequest_emptyResult_returnsNil() async throws {
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/get_my_join_request")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let result = try await apiClient.myJoinRequest()

        XCTAssertNil(result)
    }
}

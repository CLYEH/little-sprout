import Foundation
@testable import LittleSprout
import Supabase
import XCTest

/// `SupabaseFamilyAPIClient` 對 LS-33/37 的 RPC／`families` 表做編碼/解碼與錯誤映射，
/// 用 `MockURLProtocol` 攔截請求（不打真網路）。多數方法要求呼叫者已登入，所以每個測試
/// 先透過 `signIn(_:userID:)` 讓底下的 `SupabaseClient` 處於已登入狀態，再測目標方法。
final class SupabaseFamilyAPIClientTests: XCTestCase {
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func test_createFamily_success_sendsCreatedByAndDecodesFamily() async throws {
        let client = TestSupabaseClient.make { [userID, familyID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200,
                    body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            XCTAssertEqual(request.url?.path, "/rest/v1/families")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: String]
            )
            XCTAssertEqual(payload["name"], "葉家")
            XCTAssertEqual(payload["created_by"], userID.uuidString)

            return MockURLProtocol.StubResponse(statusCode: 201, body: Data("""
            {
              "id": "\(familyID.uuidString)",
              "name": "葉家",
              "created_by": "\(userID.uuidString)",
              "created_at": "2026-08-24T00:00:00Z",
              "require_approval": true
            }
            """.utf8))
        }
        try await signIn(client: client)

        let apiClient = SupabaseFamilyAPIClient(client: client)
        let family = try await apiClient.createFamily(name: "葉家")

        XCTAssertEqual(family.id, familyID)
        XCTAssertEqual(family.name, "葉家")
        XCTAssertEqual(family.createdBy, userID)
        XCTAssertTrue(family.requireApproval)
    }

    func test_createFamily_notSignedIn_throwsRejectedWithoutSendingRequest() async {
        // 不用「handler 被呼叫就 XCTFail」的寫法：SupabaseClient 初始化會起一個背景 Task
        // 監聽 authStateChanges，時序上不保證這個測試方法執行期間完全不觸發它（同一個顧慮
        // 見 test_currentSession_initiallyNil）。這條測試要守的是 createFamily 本身的行為
        // （guard 未登入直接 throw，不呼叫 REST），用回傳值斷言即可涵蓋。
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("{}".utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        do {
            _ = try await apiClient.createFamily(name: "葉家")
            XCTFail("未登入應該要 throw")
        } catch let error as AppError {
            guard case .rejected = error else {
                return XCTFail("未登入應映射為 .rejected，實際是 \(error)")
            }
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    func test_createFamily_ownerRlsRejection_mapsToRejected() async throws {
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200,
                    body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            return MockURLProtocol.StubResponse(statusCode: 403, body: Data("""
            {"code":"42501","message":"new row violates row-level security policy"}
            """.utf8))
        }
        try await signIn(client: client)

        let apiClient = SupabaseFamilyAPIClient(client: client)

        do {
            _ = try await apiClient.createFamily(name: "葉家")
            XCTFail("RLS 拒絕應該要 throw")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("42501 應映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "42501")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    func test_createInvite_success_returnsCode() async throws {
        let client = TestSupabaseClient.make { [userID, familyID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200,
                    body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/create_invite")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_family_id"] as? String, familyID.uuidString)
            XCTAssertEqual(payload["p_role"] as? String, "member")
            XCTAssertEqual(payload["p_max_uses"] as? Int, 5)

            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("\"ABCD1234\"".utf8))
        }
        try await signIn(client: client)

        let apiClient = SupabaseFamilyAPIClient(client: client)
        let code = try await apiClient.createInvite(
            familyID: familyID,
            role: .member,
            expiresAt: Date().addingTimeInterval(86400),
            maxUses: 5
        )

        XCTAssertEqual(code, "ABCD1234")
    }

    func test_createInvite_expiredCodeLimitError_mapsToValidationRetryable() async throws {
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200,
                    body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            // LS017：supabase/migrations/20260823010000_join_approval.sql——參數不合法。
            return MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS017","message":"邀請碼的可用次數必須介於 1 到 20 之間"}
            """.utf8))
        }
        try await signIn(client: client)

        let apiClient = SupabaseFamilyAPIClient(client: client)

        do {
            _ = try await apiClient.createInvite(
                familyID: familyID, role: .member, expiresAt: Date().addingTimeInterval(86400), maxUses: 999
            )
            XCTFail("應該要 throw")
        } catch let error as AppError {
            guard case .validationRetryable(_, let code) = error else {
                return XCTFail("LS017 應映射為 .validationRetryable，實際是 \(error)")
            }
            XCTAssertEqual(code, "LS017")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
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

    func test_myJoinRequest_emptyResult_returnsNil() async throws {
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/get_my_join_request")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let result = try await apiClient.myJoinRequest()

        XCTAssertNil(result)
    }

    // MARK: - Helpers

    /// 直接用底下的 `AuthClient` 走一次 Sign in with Apple 流程（走 mock，不打真網路），
    /// 讓 client 進入「已登入」狀態，供需要 `auth.uid()` 的家庭 API 測試使用。
    private func signIn(client: SupabaseClient) async throws {
        _ = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: "fake", nonce: "fake")
        )
    }
}

private extension URLRequest {
    /// `httpBody` 在透過 `URLSession` 實際送出的請求裡常常搬到 `httpBodyStream`，
    /// `MockURLProtocol` 攔截到的 `request` 是 `URLProtocol` 轉譯過的版本，直接讀
    /// `httpBody` 通常仍然有值；這裡集中處理，避免每個測試各自重複同一段判斷。
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}

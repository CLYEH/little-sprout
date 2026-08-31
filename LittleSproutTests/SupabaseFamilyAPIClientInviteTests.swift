import Foundation
@testable import LittleSprout
import Supabase
import XCTest

/// `SupabaseFamilyAPIClient` 的邀請碼生命週期（`createInvite`／`fetchLatestActiveInvite`／
/// `revokeInvite`）——R1 F2/F4：`create_invite` RPC 只回傳 `code`，client 端反查 `invites`
/// 表拿 `id`／`used_count`；`fetchLatestActiveInvite` 供 07 進場顯示既有碼；`revokeInvite`
/// 是撤銷唯一路徑。家庭建立/更新的測試在 `SupabaseFamilyAPIClientTests`——純粹是 SwiftLint
/// `type_body_length`（250 行）撞到才拆檔，兩者共用同一份 Support（同
/// `SupabaseFamilyAPIClientJoinTests` 的拆檔理由）。
final class SupabaseFamilyAPIClientInviteTests: XCTestCase {
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    override func tearDown() {
        // 見 SupabaseAuthServiceTests 同名 tearDown 的說明：MockURLProtocol 的 handler
        // 是全域 static，測試之間必須清乾淨（LS-49 PR #63 review F9）。
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func test_createInvite_success_returnsInviteRecordWithIDAndUsedCount() async throws {
        // R1 F2/F4：`create_invite` RPC 只回傳 code，`SupabaseFamilyAPIClient` 必須反查
        // `invites` 表才拿得到 `id`（撤銷用）／`used_count`（顯示用）——這裡釘住兩段請求都送對。
        let inviteID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let client = TestSupabaseClient.make { [userID, familyID, inviteID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200,
                    body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            if request.url?.path == "/rest/v1/rpc/create_invite" {
                let body = try XCTUnwrap(request.bodyData)
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(payload["p_family_id"] as? String, familyID.uuidString)
                XCTAssertEqual(payload["p_role"] as? String, "member")
                XCTAssertEqual(payload["p_max_uses"] as? Int, 5)
                // SDK 的預設 Date 編碼不帶時區指示（Helpers/DateFormatter.swift 的
                // `iso8601String`），直接送給 Postgres 的 timestamptz 會依資料庫 session
                // timezone 解讀，不保證是 UTC——client 端改成自己用 ISO8601DateFormatter 明確
                // 帶 'Z'（LS-49 PR #63 review F8）。這裡釘住 wire 上真的長這樣，不只是釘住
                // Swift 端 Date 值本身。
                let expiresAtWire = try XCTUnwrap(payload["p_expires_at"] as? String)
                XCTAssertTrue(expiresAtWire.hasSuffix("Z"), "p_expires_at 應以 'Z' 結尾，實際是 \(expiresAtWire)")
                return MockURLProtocol.StubResponse(statusCode: 200, body: Data("\"ABCD1234\"".utf8))
            }
            XCTAssertEqual(request.url?.path, "/rest/v1/invites")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.query?.contains("code=eq.ABCD1234"), true)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {
              "id": "\(inviteID.uuidString)",
              "code": "ABCD1234",
              "role": "member",
              "max_uses": 5,
              "used_count": 0,
              "expires_at": "2026-09-01T00:00:00Z"
            }
            """.utf8))
        }
        try await signIn(client: client)

        let apiClient = SupabaseFamilyAPIClient(client: client)
        let record = try await apiClient.createInvite(
            familyID: familyID,
            role: .member,
            expiresAt: Date().addingTimeInterval(86400),
            maxUses: 5
        )

        XCTAssertEqual(record.id, inviteID)
        XCTAssertEqual(record.code, "ABCD1234")
        XCTAssertEqual(record.usedCount, 0)
    }

    func test_fetchLatestActiveInvite_hasActiveInvite_returnsRecord() async throws {
        let inviteID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let client = TestSupabaseClient.make { [familyID, inviteID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/invites")
            XCTAssertEqual(request.httpMethod, "GET")
            // R2 N6：「未過期」只靠這一行 `.gt("expires_at", ...)` filter 撐著（「還有名額」有
            // 記憶體端過濾＋專門測試，這個沒有）——拿掉那一行三條 fetchLatestActiveInvite 測試
            // 照樣綠，後果是過期碼被當有效碼顯示給 owner。這裡釘住 wire 上真的送了這個 filter，
            // 比照同檔 `createInvite` 已經在驗 wire 的作法（R2 comment `9dfd1a9c`）。
            XCTAssertEqual(request.url?.query?.contains("expires_at=gt."), true)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "id": "\(inviteID.uuidString)",
              "code": "EXIST1",
              "role": "member",
              "max_uses": 5,
              "used_count": 2,
              "expires_at": "2026-09-01T00:00:00Z"
            }]
            """.utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let record = try await apiClient.fetchLatestActiveInvite(familyID: familyID)

        XCTAssertEqual(record?.id, inviteID)
        XCTAssertEqual(record?.usedCount, 2)
    }

    func test_fetchLatestActiveInvite_onlyExhaustedCandidate_returnsNil() async throws {
        // PostgREST 篩不了 used_count < max_uses（兩邊都是欄位），client 端自己篩（R1 F4）——
        // 這裡驗證用罄的那一支不會被誤判成「還有效」。
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "id": "77777777-7777-7777-7777-777777777777",
              "code": "USEDUP",
              "role": "member",
              "max_uses": 5,
              "used_count": 5,
              "expires_at": "2026-09-01T00:00:00Z"
            }]
            """.utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let record = try await apiClient.fetchLatestActiveInvite(familyID: familyID)

        XCTAssertNil(record)
    }

    func test_fetchLatestActiveInvite_none_returnsNil() async throws {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let record = try await apiClient.fetchLatestActiveInvite(familyID: familyID)

        XCTAssertNil(record)
    }

    func test_revokeInvite_success_doesNotThrow() async throws {
        let inviteID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let client = TestSupabaseClient.make { [inviteID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/invites")
            XCTAssertEqual(request.httpMethod, "DELETE")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "id": "\(inviteID.uuidString)",
              "code": "OLD001",
              "role": "member",
              "max_uses": 5,
              "used_count": 0,
              "expires_at": "2026-09-01T00:00:00Z"
            }]
            """.utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        try await apiClient.revokeInvite(id: inviteID)
    }

    func test_revokeInvite_notOwnerOrAlreadyGone_throwsRejected() async {
        // invites_delete policy 是 USING 過濾：非 owner／已經不存在的列，DELETE 本身不出錯，
        // 只是匹配 0 列——client 端要把「0 列受影響」翻成錯誤，不能讓呼叫端誤以為真的撤銷了
        // （R1 F2：不能讓 owner 以為舊碼已作廢，其實還活著）。
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        do {
            try await apiClient.revokeInvite(id: UUID())
            XCTFail("0 列受影響應該要 throw")
        } catch let error as AppError {
            guard case .rejected = error else {
                return XCTFail("0 列受影響應映射為 .rejected，實際是 \(error)")
            }
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
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

    // MARK: - Helpers

    /// 直接用底下的 `AuthClient` 走一次 Sign in with Apple 流程（走 mock，不打真網路），
    /// 讓 client 進入「已登入」狀態，供需要 `auth.uid()` 的家庭 API 測試使用。
    private func signIn(client: SupabaseClient) async throws {
        _ = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: "fake", nonce: "fake")
        )
    }
}

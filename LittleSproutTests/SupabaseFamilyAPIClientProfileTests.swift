import Foundation
@testable import LittleSprout
import Supabase
import XCTest

/// `SupabaseFamilyAPIClient+Profile`（LS-192 03 家庭成員清單／移除／轉移家庭管理者 ＋ 02
/// 個人 profile 讀寫）的 wire-level 測試——用 `MockURLProtocol` 斷言真正送出的 HTTP path／
/// query／body，不是只測「回應解碼得出正確的 Swift 值」。R2（merge-review R1 M7）：R1 這
/// 七支方法完全沒有這一層測試，`.rpc("transfer_ownership")` 改名成
/// `.rpc("transfer_ownership_MUTANT")` 這種 mutation 不會被任何測試抓到（`Executed 680
/// tests, with 0 failures`）——這裡逐支補上，理由與慣例同
/// `SupabaseFamilyAPIClientJoinTests`（`request.url?.path` 斷言，同一份 Support）。
final class SupabaseFamilyAPIClientProfileTests: XCTestCase {
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let otherUserID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let familyID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    override func tearDown() {
        // 見 SupabaseAuthServiceTests 同名 tearDown 的說明：MockURLProtocol 的 handler
        // 是全域 static，測試之間必須清乾淨（LS-49 PR #63 review F9）。
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    // MARK: - listMembers

    func test_listMembers_sendsFamilyIDFilterAndProfilesEmbedSelect_decodesJoinedRow() async throws {
        let client = TestSupabaseClient.make { [familyID, userID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/family_members")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("family_id=eq.\(familyID.uuidString)"), "應該用 family_id 過濾，實際 query：\(query)")
            // M7 明列「listMembers 的 select 字串」——斷言真的帶了 profiles embed，不只是
            // 「有 select 參數」這種弱斷言（改成不帶 embed 的 mutation 也會被這裡抓到）。
            XCTAssertTrue(
                query.contains("profiles") && query.contains("display_name") && query.contains("avatar_url"),
                "select 應該內嵌 profiles(display_name,avatar_url)，實際 query：\(query)"
            )
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"user_id":"\(userID.uuidString)","role":"owner",
              "profiles":{"display_name":"陳美玲","avatar_url":null}}]
            """.utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let members = try await apiClient.listMembers(familyID: familyID)

        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members[0].userID, userID)
        XCTAssertEqual(members[0].role, .owner)
        XCTAssertEqual(members[0].displayName, "陳美玲")
    }

    // MARK: - removeMember

    func test_removeMember_sendsDeleteWithFamilyIDAndUserIDFilters() async throws {
        let client = TestSupabaseClient.make { [familyID, otherUserID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/family_members")
            XCTAssertEqual(request.httpMethod, "DELETE")
            let query = request.url?.query ?? ""
            // M7 明列「removeMember 的兩個 eq」——分開斷言兩個過濾條件都真的送出去了。
            XCTAssertTrue(query.contains("family_id=eq.\(familyID.uuidString)"), "缺 family_id 過濾：\(query)")
            XCTAssertTrue(query.contains("user_id=eq.\(otherUserID.uuidString)"), "缺 user_id 過濾：\(query)")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"user_id":"\(otherUserID.uuidString)"}]
            """.utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        try await apiClient.removeMember(familyID: familyID, userID: otherUserID)
    }

    func test_removeMember_zeroRowsAffected_throwsRejected() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        do {
            try await apiClient.removeMember(familyID: familyID, userID: otherUserID)
            XCTFail("0 列受影響應該 throw，不是靜默成功")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("應該映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "no_rows_deleted")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    // MARK: - transferOwnership（M7 mutation 實測目標：`.rpc("transfer_ownership")` 改名）

    func test_transferOwnership_callsTransferOwnershipRPCPath_decodesResult() async throws {
        let client = TestSupabaseClient.make { [familyID, userID, otherUserID] request in
            // 這一行就是 M7 mutation（改成 "transfer_ownership_MUTANT"）會讓這支測試變紅的斷言。
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/transfer_ownership")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(payload["p_family_id"], familyID.uuidString)
            XCTAssertEqual(payload["p_to_user_id"], otherUserID.uuidString)
            // `.single()`（見 SupabaseFamilyAPIClient+Profile.swift）送 `Accept: application/
            // vnd.pgrst.object+json`，真正的 PostgREST 會把 1 列的陣列攤平成單一物件回來——
            // 這裡直接模擬那個攤平後的形狀（物件，不是陣列），不是 RPC 本身 SQL 定義的
            // `returns table(...)` 陣列形狀。
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {"from_user_id":"\(userID.uuidString)","from_role":"member",
             "to_user_id":"\(otherUserID.uuidString)","to_role":"owner"}
            """.utf8))
        }
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let result = try await apiClient.transferOwnership(familyID: familyID, toUserID: otherUserID)

        XCTAssertEqual(result.fromUserID, userID)
        XCTAssertEqual(result.fromRole, .member)
        XCTAssertEqual(result.toUserID, otherUserID)
        XCTAssertEqual(result.toRole, .owner)
    }

    // MARK: - fetchMyProfile／updateDisplayName／updateAvatarPath（皆需要先登入，`auth.uid()`）

    func test_fetchMyProfile_sendsSelfIDFilter_decodesProfile() async throws {
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "me@example.com")
                )
            }
            XCTAssertEqual(request.url?.path, "/rest/v1/profiles")
            XCTAssertEqual(request.httpMethod, "GET")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("id=eq.\(userID.uuidString)"), "應該用自己的 id 過濾，實際 query：\(query)")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {"id":"\(userID.uuidString)","display_name":"陳美玲","avatar_url":null}
            """.utf8))
        }
        try await signIn(client: client)
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let profile = try await apiClient.fetchMyProfile()

        XCTAssertEqual(profile.id, userID)
        XCTAssertEqual(profile.displayName, "陳美玲")
    }

    func test_updateDisplayName_sendsPatchWithSelfIDFilterAndBody() async throws {
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "me@example.com")
                )
            }
            XCTAssertEqual(request.url?.path, "/rest/v1/profiles")
            XCTAssertEqual(request.httpMethod, "PATCH")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("id=eq.\(userID.uuidString)"), "應該只能改自己，實際 query：\(query)")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(payload["display_name"], "陳小華")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {"id":"\(userID.uuidString)","display_name":"陳小華","avatar_url":null}
            """.utf8))
        }
        try await signIn(client: client)
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let profile = try await apiClient.updateDisplayName("陳小華")

        XCTAssertEqual(profile.displayName, "陳小華")
    }

    func test_updateAvatarPath_sendsPatchWithSelfIDFilterAndBody() async throws {
        let path = "\(familyID.uuidString.lowercased())/avatars/\(userID.uuidString.lowercased()).jpg"
        let client = TestSupabaseClient.make { [userID, path] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "me@example.com")
                )
            }
            XCTAssertEqual(request.url?.path, "/rest/v1/profiles")
            XCTAssertEqual(request.httpMethod, "PATCH")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("id=eq.\(userID.uuidString)"), "應該只能改自己，實際 query：\(query)")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(payload["avatar_url"], path)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {"id":"\(userID.uuidString)","display_name":"陳美玲","avatar_url":"\(path)"}
            """.utf8))
        }
        try await signIn(client: client)
        let apiClient = SupabaseFamilyAPIClient(client: client)

        let profile = try await apiClient.updateAvatarPath(path)

        XCTAssertEqual(profile.avatarURL, path)
    }

    // MARK: - Helpers

    /// 同 `SupabaseFamilyAPIClientTests.signIn`：走 mock 的 Sign in with Apple 流程，讓 client
    /// 進入「已登入」狀態，供需要 `auth.uid()` 的呼叫使用。
    private func signIn(client: SupabaseClient) async throws {
        _ = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: "fake", nonce: "fake")
        )
    }
}

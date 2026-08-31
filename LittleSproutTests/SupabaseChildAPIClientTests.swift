import Auth
import Foundation
@testable import LittleSprout
import Supabase
import XCTest

/// `SupabaseChildAPIClient` 對 `list_children`／`create_child`／`update_child`／
/// `set_child_deleted` 四支 RPC 與 `family_members` 角色查詢的編碼/解碼與錯誤映射。用
/// `MockURLProtocol` 攔截請求（不打真網路），同 `SupabaseFamilyAPIClientTests` 的模式。
final class SupabaseChildAPIClientTests: XCTestCase {
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let childID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func test_listChildren_decodesRows() async throws {
        let client = TestSupabaseClient.make { [familyID, childID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/list_children")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_family_id"] as? String, familyID.uuidString)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "id": "\(childID.uuidString)",
              "name": "陳小安",
              "birthday": "2024-03-12",
              "avatar_url": null,
              "deleted_at": null,
              "created_at": "2026-08-24T00:00:00Z"
            }]
            """.utf8))
        }
        let apiClient = SupabaseChildAPIClient(client: client)

        let children = try await apiClient.listChildren(familyID: familyID)

        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children[0].id, childID)
        XCTAssertEqual(children[0].name, "陳小安")
        XCTAssertNil(children[0].avatarURL)
        XCTAssertNil(children[0].deletedAt)
        XCTAssertEqual(BirthdayFormat.displayString(from: children[0].birthday), "2024年3月12日")
    }

    func test_createChild_sendsWireBirthdayAsPlainDate_decodesID() async throws {
        let client = TestSupabaseClient.make { [familyID, childID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/create_child")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_family_id"] as? String, familyID.uuidString)
            XCTAssertEqual(payload["p_name"] as? String, "陳小安")
            // 純日期字串，不帶時間／時區——見 BirthdayFormat 文件註解。
            XCTAssertEqual(payload["p_birthday"] as? String, "2024-03-12")
            // R1：`p_avatar_url` 沒有 SQL 預設值，PostgREST 用具名參數比對函式簽章時
            // 要求這個 key 一定要出現在 body 裡（就算值是 null）——`nil` 時「整個省略
            // 這個 key」會讓 PostgREST 找不到函式簽章、回 404（PGRST202）。這裡明確斷言
            // key 存在且值為 `NSNull`，不能只斷言「轉型成 String 後是 nil」（那樣「key
            // 缺席」跟「key 存在但值是 null」兩種情況都會通過，測不出這個 bug）。
            XCTAssertTrue(payload.keys.contains("p_avatar_url"), "p_avatar_url 這個 key 不能被省略")
            XCTAssertTrue(payload["p_avatar_url"] is NSNull, "avatarURL 為 nil 時應送明確的 JSON null")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("\"\(childID.uuidString)\"".utf8))
        }
        let apiClient = SupabaseChildAPIClient(client: client)
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 12
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let birthday = try XCTUnwrap(utcCalendar.date(from: components))

        let resultID = try await apiClient.createChild(
            familyID: familyID, name: "陳小安", birthday: birthday, avatarURL: nil
        )

        XCTAssertEqual(resultID, childID)
    }

    func test_createChild_invalidName_mapsToValidationRetryable() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"23514","message":"new row for relation \\"children\\" violates check constraint"}
            """.utf8))
        }
        let apiClient = SupabaseChildAPIClient(client: client)

        do {
            _ = try await apiClient.createChild(familyID: familyID, name: "", birthday: Date(), avatarURL: nil)
            XCTFail("不合法的姓名應該要 throw")
        } catch let error as AppError {
            guard case .validationRetryable(_, let code) = error else {
                return XCTFail("23514 應映射為 .validationRetryable，實際是 \(error)")
            }
            XCTAssertEqual(code, "23514")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    func test_updateChild_success_sendsExpectedParams() async throws {
        let client = TestSupabaseClient.make { [childID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/update_child")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_child_id"] as? String, childID.uuidString)
            XCTAssertEqual(payload["p_name"] as? String, "陳小安")
            XCTAssertEqual(payload["p_birthday"] as? String, "2024-03-12")
            // 同 createChild 的理由（見該測試註解）：`p_avatar_url` 沒有 SQL 預設值，
            // key 不能被省略。
            XCTAssertTrue(payload.keys.contains("p_avatar_url"), "p_avatar_url 這個 key 不能被省略")
            XCTAssertTrue(payload["p_avatar_url"] is NSNull, "avatarURL 為 nil 時應送明確的 JSON null")
            return MockURLProtocol.StubResponse(statusCode: 204, body: Data())
        }
        let apiClient = SupabaseChildAPIClient(client: client)
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 12
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let birthday = try XCTUnwrap(utcCalendar.date(from: components))

        try await apiClient.updateChild(childID: childID, name: "陳小安", birthday: birthday, avatarURL: nil)
    }

    func test_updateChild_notEditableByCaller_mapsToRejected() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS042","message":"不是仍是該家庭 owner/member 的成員"}
            """.utf8))
        }
        let apiClient = SupabaseChildAPIClient(client: client)

        do {
            try await apiClient.updateChild(childID: childID, name: "x", birthday: Date(), avatarURL: nil)
            XCTFail("LS042 應該要 throw")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("LS042 應映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "LS042")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    func test_setChildDeleted_softDelete_sendsExpectedParams() async throws {
        let client = TestSupabaseClient.make { [childID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/set_child_deleted")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_child_id"] as? String, childID.uuidString)
            XCTAssertEqual(payload["p_deleted"] as? Bool, true)
            return MockURLProtocol.StubResponse(statusCode: 204, body: Data())
        }
        let apiClient = SupabaseChildAPIClient(client: client)

        try await apiClient.setChildDeleted(childID: childID, deleted: true)
    }

    func test_setChildDeleted_restoreWindowExpired_mapsToRejected() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS043","message":"孩子檔案已被移除超過 30 天，無法還原"}
            """.utf8))
        }
        let apiClient = SupabaseChildAPIClient(client: client)

        do {
            try await apiClient.setChildDeleted(childID: childID, deleted: false)
            XCTFail("LS043 應該要 throw")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("LS043 應映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "LS043")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    // MARK: - fetchMyRole

    func test_fetchMyRole_hasRow_decodesRole() async throws {
        let client = TestSupabaseClient.make { [userID, familyID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200,
                    body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            XCTAssertEqual(request.url?.path, "/rest/v1/family_members")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.query?.contains("family_id=eq.\(familyID.uuidString)"), true)
            XCTAssertEqual(request.url?.query?.contains("user_id=eq.\(userID.uuidString)"), true)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"role":"owner"}]
            """.utf8))
        }
        try await signIn(client: client)
        let apiClient = SupabaseChildAPIClient(client: client)

        let role = try await apiClient.fetchMyRole(familyID: familyID)

        XCTAssertEqual(role, .owner)
    }

    func test_fetchMyRole_noRow_returnsNil() async throws {
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200,
                    body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        try await signIn(client: client)
        let apiClient = SupabaseChildAPIClient(client: client)

        let role = try await apiClient.fetchMyRole(familyID: familyID)

        XCTAssertNil(role)
    }

    // MARK: - Helpers

    private func signIn(client: SupabaseClient) async throws {
        _ = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: "fake", nonce: "fake")
        )
    }
}

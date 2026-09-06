import Foundation
@testable import LittleSprout
import XCTest

/// `SupabaseEULAAPIClient` 對 `app_settings.eula_version` 讀取、`profiles.eula_accepted_version`
/// 讀取、`accept_eula` RPC 的編碼與錯誤映射。用 `MockURLProtocol` 攔截請求（不打真網路），
/// 同 `SupabaseDiaryAPIClientTests` 的模式。
final class SupabaseEULAAPIClientTests: XCTestCase {
    private let userID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func test_fetchCurrentVersion_decodesEulaVersion_withoutFilteringOnId() async throws {
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/app_settings")
            XCTAssertEqual(request.httpMethod, "GET")
            // docs/API.md §4：查詢不得引用 `id` 欄位（欄位級權限涵蓋任何位置的引用，不只
            // 投影欄位）——釘住 wire 上真的沒有帶 `id=` 這個 query 片段。
            XCTAssertEqual(request.url?.query?.contains("id="), false)
            XCTAssertEqual(request.url?.query?.contains("select=eula_version"), true)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {"eula_version":"2026-09-05-draft"}
            """.utf8))
        }
        let apiClient = SupabaseEULAAPIClient(client: client)

        let version = try await apiClient.fetchCurrentVersion()

        XCTAssertEqual(version, "2026-09-05-draft")
    }

    func test_fetchAcceptedVersion_hasRecord_decodesVersion() async throws {
        let client = TestSupabaseClient.make { [userID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/profiles")
            XCTAssertEqual(request.url?.query?.contains("id=eq.\(userID.uuidString)"), true)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {"eula_accepted_version":"2026-08-01-draft"}
            """.utf8))
        }
        let apiClient = SupabaseEULAAPIClient(client: client)

        let version = try await apiClient.fetchAcceptedVersion(userID: userID)

        XCTAssertEqual(version, "2026-08-01-draft")
    }

    func test_fetchAcceptedVersion_neverAccepted_returnsNil() async throws {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {"eula_accepted_version":null}
            """.utf8))
        }
        let apiClient = SupabaseEULAAPIClient(client: client)

        let version = try await apiClient.fetchAcceptedVersion(userID: userID)

        XCTAssertNil(version)
    }

    func test_acceptEULA_success_sendsVersionParam() async throws {
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/accept_eula")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_version"] as? String, "2026-09-05-draft")
            return MockURLProtocol.StubResponse(statusCode: 204, body: Data())
        }
        let apiClient = SupabaseEULAAPIClient(client: client)

        try await apiClient.acceptEULA(version: "2026-09-05-draft")
    }

    func test_acceptEULA_versionMismatch_mapsToRejectedWithLS055() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS055","message":"條款版本已更新，請重新閱讀"}
            """.utf8))
        }
        let apiClient = SupabaseEULAAPIClient(client: client)

        do {
            try await apiClient.acceptEULA(version: "已過期版本")
            XCTFail("LS055 應該要 throw")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("LS055 應映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "LS055")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    func test_acceptEULA_profileMissing_mapsToRejectedWithLS056() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS056","message":"帳號資料異常，請聯絡我們"}
            """.utf8))
        }
        let apiClient = SupabaseEULAAPIClient(client: client)

        do {
            try await apiClient.acceptEULA(version: "2026-09-05-draft")
            XCTFail("LS056 應該要 throw")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("LS056 應映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "LS056")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }
}

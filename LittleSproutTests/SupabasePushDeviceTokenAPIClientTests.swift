import Foundation
@testable import LittleSprout
import XCTest

/// `SupabasePushDeviceTokenAPIClient` 對 `register_device_token` RPC 的編碼與錯誤映射。用
/// `MockURLProtocol` 攔截請求（不打真網路），同 `SupabaseEULAAPIClientTests` 的模式。
final class SupabasePushDeviceTokenAPIClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func test_registerDeviceToken_sendsTokenAndPlatformParams() async throws {
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/register_device_token")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_token"] as? String, "deadbeef")
            XCTAssertEqual(payload["p_platform"] as? String, "ios")
            return MockURLProtocol.StubResponse(statusCode: 204, body: Data())
        }
        let apiClient = SupabasePushDeviceTokenAPIClient(client: client)

        try await apiClient.registerDeviceToken(token: "deadbeef", platform: "ios")
    }

    /// `docs/API.md` §4：未登入呼叫這支 RPC 會回 `42501`——確認錯誤有映射成 `AppError`，
    /// 不是把 PostgREST 的原始 error 型別往外拋。
    func test_registerDeviceToken_notAuthenticated_mapsToAppError() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 401, body: Data("""
            {"code":"42501","message":"permission denied"}
            """.utf8))
        }
        let apiClient = SupabasePushDeviceTokenAPIClient(client: client)

        do {
            try await apiClient.registerDeviceToken(token: "deadbeef", platform: "ios")
            XCTFail("預期拋出錯誤")
        } catch {
            XCTAssertTrue(error is AppError, "錯誤應該映射成 AppError，不是原始 PostgREST error 型別")
        }
    }
}

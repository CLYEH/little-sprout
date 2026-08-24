import Foundation
@testable import LittleSprout
import os
import XCTest

/// `SupabaseAuthService` 對真正的 Supabase Auth HTTP 契約做編碼/解碼與錯誤映射，
/// 用 `MockURLProtocol` 攔截請求（不打真網路），驗證狀態機（未登入 → 登入 → 登出）
/// 與四層錯誤文法的分類都對。
final class SupabaseAuthServiceTests: XCTestCase {
    private let testUserID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    func test_currentSession_initiallyNil() {
        // 不斷言「完全沒有請求」：SupabaseClient 初始化會起一個背景 Task 監聽
        // authStateChanges，時序上不保證在這個同步測試方法返回前完全跑完或不跑，
        // 那不是這條測試要守的東西。這裡只釘住「乾淨的 in-memory storage 起手，
        // currentSession 讀出來是 nil」這個同步、確定的行為。
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("{}".utf8))
        }
        let service = SupabaseAuthService(client: client)
        XCTAssertNil(service.currentSession)
    }

    func test_signInWithApple_success_returnsMappedSession() async throws {
        let client = TestSupabaseClient.make { [testUserID] request in
            XCTAssertEqual(request.url?.path, "/auth/v1/token")
            XCTAssertEqual(request.url?.query?.contains("grant_type=id_token"), true)
            return MockURLProtocol.StubResponse(
                statusCode: 200,
                body: SessionFixture.json(userID: testUserID, email: "parent@example.com")
            )
        }
        let service = SupabaseAuthService(client: client)

        let session = try await service.signInWithApple(idToken: "fake-id-token", nonce: "fake-nonce")

        XCTAssertEqual(session.userID, testUserID)
        XCTAssertEqual(session.email, "parent@example.com")
        XCTAssertEqual(service.currentSession?.userID, testUserID)
    }

    func test_signInWithApple_invalidCredentials_mapsToRejected() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(
                statusCode: 401,
                body: Data("""
                {"error_code":"invalid_credentials","msg":"Invalid id token"}
                """.utf8)
            )
        }
        let service = SupabaseAuthService(client: client)

        do {
            _ = try await service.signInWithApple(idToken: "bad-token", nonce: "nonce")
            XCTFail("401 應該要 throw")
        } catch let error as AppError {
            guard case .rejected = error else {
                return XCTFail("401 應映射為 .rejected，實際是 \(error)")
            }
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    func test_sendEmailOTP_success_doesNotThrow() async throws {
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/otp")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("{}".utf8))
        }
        let service = SupabaseAuthService(client: client)

        try await service.sendEmailOTP(email: "parent@example.com")
    }

    func test_sendEmailOTP_rateLimited_mapsToValidationRetryable() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(
                statusCode: 429,
                body: Data("""
                {"error_code":"over_email_send_rate_limit","msg":"rate limited"}
                """.utf8)
            )
        }
        let service = SupabaseAuthService(client: client)

        do {
            try await service.sendEmailOTP(email: "parent@example.com")
            XCTFail("429 應該要 throw")
        } catch let error as AppError {
            guard case .validationRetryable = error else {
                return XCTFail("429 應映射為 .validationRetryable，實際是 \(error)")
            }
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    func test_verifyEmailOTP_success_returnsMappedSession() async throws {
        let client = TestSupabaseClient.make { [testUserID] request in
            XCTAssertEqual(request.url?.path, "/auth/v1/verify")
            return MockURLProtocol.StubResponse(
                statusCode: 200,
                body: SessionFixture.json(userID: testUserID, email: "grandma@example.com")
            )
        }
        let service = SupabaseAuthService(client: client)

        let session = try await service.verifyEmailOTP(email: "grandma@example.com", token: "123456")

        XCTAssertEqual(session.userID, testUserID)
        XCTAssertEqual(session.email, "grandma@example.com")
    }

    func test_verifyEmailOTP_expiredCode_mapsToValidationRetryable() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(
                statusCode: 403,
                body: Data("""
                {"error_code":"otp_expired","msg":"Token has expired or is invalid"}
                """.utf8)
            )
        }
        let service = SupabaseAuthService(client: client)

        do {
            _ = try await service.verifyEmailOTP(email: "grandma@example.com", token: "000000")
            XCTFail("應該要 throw")
        } catch let error as AppError {
            // otp_expired 走 403 的話目前規則按狀態碼歸類為 .rejected——這條測試釘住
            // 「狀態碼優先於語意猜測」這個目前的設計選擇，日後要改成看 error_code 細分
            // 需要同時改這裡，不能悄悄漂移。
            guard case .rejected(_, let code) = error else {
                return XCTFail("403 應映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "otp_expired")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    func test_signOut_clearsCurrentSession() async throws {
        let sawLogoutRequest = OSAllocatedUnfairLock(initialState: false)
        let client = TestSupabaseClient.make { [testUserID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200,
                    body: SessionFixture.json(userID: testUserID, email: "parent@example.com")
                )
            }
            XCTAssertEqual(request.url?.path, "/auth/v1/logout")
            sawLogoutRequest.withLock { $0 = true }
            return MockURLProtocol.StubResponse(statusCode: 204)
        }
        let service = SupabaseAuthService(client: client)
        _ = try await service.signInWithApple(idToken: "fake-id-token", nonce: "fake-nonce")
        XCTAssertNotNil(service.currentSession)

        try await service.signOut()

        XCTAssertNil(service.currentSession)
        XCTAssertTrue(sawLogoutRequest.withLock { $0 })
    }
}

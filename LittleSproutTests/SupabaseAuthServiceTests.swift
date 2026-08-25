import Foundation
@testable import LittleSprout
import os
import Supabase
import XCTest

/// `SupabaseAuthService` 對真正的 Supabase Auth HTTP 契約做編碼/解碼與錯誤映射，
/// 用 `MockURLProtocol` 攔截請求（不打真網路），驗證狀態機（未登入 → 登入 → 登出）
/// 與四層錯誤文法的分類都對。
final class SupabaseAuthServiceTests: XCTestCase {
    private let testUserID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    override func tearDown() {
        // MockURLProtocol 的 handler 是全域 static——不清掉的話，這個測試最後設的 handler
        // 會被下一個測試方法的第一個請求（例如它自己還沒來得及呼叫 TestSupabaseClient.make
        // 之前，某個背景 Task 剛好先發了請求）誤用，變成難查的跨測試汙染（LS-49 PR #63 review F9）。
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

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

    func test_refreshSession_success_returnsAndCachesNewSession() async throws {
        let client = TestSupabaseClient.make { [testUserID] request in
            if request.url?.query?.contains("grant_type=id_token") == true {
                return MockURLProtocol.StubResponse(
                    statusCode: 200,
                    body: SessionFixture.json(userID: testUserID, email: "parent@example.com")
                )
            }
            XCTAssertEqual(request.url?.path, "/auth/v1/token")
            XCTAssertEqual(request.url?.query?.contains("grant_type=refresh_token"), true)
            return MockURLProtocol.StubResponse(
                statusCode: 200,
                body: SessionFixture.json(userID: testUserID, email: "refreshed@example.com")
            )
        }
        let service = SupabaseAuthService(client: client)
        _ = try await service.signInWithApple(idToken: "fake-id-token", nonce: "fake-nonce")

        let refreshed = try await service.refreshSession()

        XCTAssertEqual(refreshed.email, "refreshed@example.com")
        // `refreshSession()` 自己的 `updateCache` 同步寫回快取（見 SupabaseAuthService 的
        // updateCache 註解），不必等 authStateChanges 背景監聽——這裡釘住的是這條同步路徑。
        XCTAssertEqual(service.currentSession?.email, "refreshed@example.com")
    }

    func test_authStateChanges_backgroundRefresh_updatesCacheAsynchronously() async throws {
        // N2：快取有兩條更新路徑（見 SupabaseAuthService 的 cachedSession 欄位註解）——
        // 上面的 test_refreshSession_success 測的是①（方法自己同步 updateCache）。這裡故意
        // 繞過 SupabaseAuthService 自己的方法，直接呼叫底層 `client.auth.refreshSession()`，
        // 只有②（`observeAuthChangesTask` 監聽 `authStateChanges`）能讓快取跟著更新——
        // 用來釘住「不靠 SupabaseAuthService 自己的方法呼叫、SDK 自己觸發的 session 變化
        // （例如 autoRefreshToken 計時器）」這條非同步路徑真的有把快取同步進去。
        let client = TestSupabaseClient.make { [testUserID] request in
            if request.url?.query?.contains("grant_type=id_token") == true {
                return MockURLProtocol.StubResponse(
                    statusCode: 200,
                    body: SessionFixture.json(userID: testUserID, email: "parent@example.com")
                )
            }
            return MockURLProtocol.StubResponse(
                statusCode: 200,
                body: SessionFixture.json(userID: testUserID, email: "background-refreshed@example.com")
            )
        }
        let service = SupabaseAuthService(client: client)
        _ = try await service.signInWithApple(idToken: "fake-id-token", nonce: "fake-nonce")
        XCTAssertEqual(service.currentSession?.email, "parent@example.com")

        _ = try await client.auth.refreshSession()

        let expectation = expectation(description: "authStateChanges 背景監聽把新 session 同步進快取")
        let pollTask = Task {
            while service.currentSession?.email != "background-refreshed@example.com" {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        pollTask.cancel()

        XCTAssertEqual(service.currentSession?.email, "background-refreshed@example.com")
    }

    func test_initialSession_offlineWithExpiredLocalSession_doesNotClearCache() async throws {
        // N1：模擬「先前登入過、session 已過期，重開 app 時網路不通」——離線回訪不該被誤判
        // 成未登入。先用一個「線上」client 登入拿到一份已過期的 session（登入 RPC 本身不驗
        // expires_at，SDK 存了什麼就是什麼），再用同一份本機儲存建第二個 client 模擬「重開
        // app」，但這次網路全斷。
        let sharedStorage = InMemoryAuthLocalStorage()
        let signInClient = TestSupabaseClient.make(storage: sharedStorage) { [testUserID] _ in
            MockURLProtocol.StubResponse(
                statusCode: 200,
                body: SessionFixture.json(
                    userID: testUserID,
                    email: "parent@example.com",
                    expiresAt: Date().addingTimeInterval(-3600)
                )
            )
        }
        _ = try await signInClient.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: "fake", nonce: "fake")
        )

        let offlineClient = TestSupabaseClient.make(storage: sharedStorage) { _ in
            throw URLError(.notConnectedToInternet)
        }
        let service = SupabaseAuthService(client: offlineClient)

        // `authStateChanges` 的 `.initialSession` 事件是背景排程送達的（見 SupabaseAuthService
        // init 的註解），這裡用 sleep 給非同步事件足夠時間跑完後再斷言（要驗的正是「保持
        // 不變」，沒有一個「變成某個值」的終態可以拿來 poll）。300ms 曾經不夠：
        // supabase-swift 的 `RetryRequestInterceptor`（`retryLimit: 2`／指數退避
        // `pow(2, retryCount) * 0.5` 秒）替 `.notConnectedToInternet` 這類錯誤重試一次，
        // 光是第一次重試前的等待就有 1 秒——sleep 300ms 時舊行為（false）根本還沒重試完、
        // `.initialSession(nil)` 事件根本還沒送達，測試在旗標是 false 時也會誤判綠燈
        // （PR #77 R1 M1 紅╱綠證明實測抓到）。2.5 秒留足夠餘裕蓋過重試延遲。
        try await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertEqual(
            service.currentSession?.userID, testUserID,
            "離線開 app 時，先前登入過的快取不該被 SDK 的 .initialSession(nil) 事件抹成 nil（N1）"
        )
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
            // .local：只登出這一台裝置，不是 SDK 預設的 .global（撤銷同帳號所有裝置的
            // session）——AuthService 協定文件寫的是「登出目前裝置的 session」
            // （LS-49 PR #63 review F1）。
            XCTAssertEqual(request.url?.query?.contains("scope=local"), true)
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

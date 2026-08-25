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

    func test_sessionUpdates_backgroundRefresh_forwardsSameSessionAsCache() async throws {
        // LS-82 review F4：舊版用 `first(where:)` 沒有逾時——轉發邏輯壞掉時（stream 不再
        // yield 目標值也不 finish）會永久掛住，直到 CI 40 分鐘 job timeout 才失敗（reviewer
        // 實測）。改用跟其餘測試一致的 2 秒 expectation：逾時就是一條看得到名字的紅測試。
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

        let forwardedEmail = OSAllocatedUnfairLock<String?>(initialState: nil)
        let expectation = expectation(description: "sessionUpdates 收到背景刷新後的 session")
        let consumeTask = Task {
            for await session in service.sessionUpdates {
                guard session?.email == "background-refreshed@example.com" else { continue }
                forwardedEmail.withLock { $0 = session?.email }
                expectation.fulfill()
                break
            }
        }

        _ = try await client.auth.refreshSession()
        await fulfillment(of: [expectation], timeout: 2)
        consumeTask.cancel()

        XCTAssertEqual(forwardedEmail.withLock { $0 }, "background-refreshed@example.com")
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

        // LS-62（LS-55 PR #77 R2 I-A）：舊版靠固定 sleep 等 supabase-swift 內建的重試攔截器
        // 把離線請求的重試序列跑完，等於把 SDK 目前的重試次數／退避秒數寫死進測試——SDK
        // 升版調整這些常數，固定 sleep 就可能在重試還沒跑完時就斷言，抓不到旗標退化（無聲
        // 假綠）。改法：離線 stub 計數被呼叫次數（下面用來斷言「真的走過離線路徑」），至於
        // 「重試真的跑完了沒」不用猜時間或次數，讓呼叫端自己也對同一個 client 額外
        // await 一次 `session`——過期 session 會走到 SDK 內部同一條 refresh 路徑，
        // 該路徑用 in-flight task 讓同一個 refresh token 的所有併發呼叫共用同一個任務，
        // 所以這裡 await 到的就是 `SupabaseAuthService` 初始化時 SDK 內部觸發的那個
        // 背景重試序列本身「真的執行完畢」，不管它這次重試了幾輪、退避多久，測試都不用
        // 知道那個數字。合流成立的條件是測試呼叫抵達時 in-flight task 仍存活；否則測試
        // 自建序列、可能提早斷言（PR #120 R1 F2）。
        let offlineCallCount = OSAllocatedUnfairLock(initialState: 0)
        let offlineClient = TestSupabaseClient.make(storage: sharedStorage) { _ in
            offlineCallCount.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let service = SupabaseAuthService(client: offlineClient)

        do {
            // 離線時這裡必須 throw：如果哪天不再 throw（SDK 不再對過期 session 走網路
            // refresh），代表上面「等到 SDK 內部重試序列跑完」的假設已經失效，這條測試
            // 的等待跟著失效——用 XCTFail 把這個情況變成看得到的紅，不要悄悄放過
            // （PR #120 R1 F1）。
            _ = try await offlineClient.auth.session
            XCTFail("離線時 auth.session 應該 throw——沒 throw 代表 SDK 不再走網路 refresh，這條測試的等待已失效")
        } catch {}

        // 短 settle：上面的 await 只保證「重試序列跑完了」，`authStateChanges` 背景監聽
        // 把對應的 `.initialSession` 事件消化進 `SupabaseAuthService` 快取仍需要一點
        // Task 排程時間（純記憶體操作、無 I/O）——留一點緩衝再斷言。實測：settle 降到
        // 1ms 時，旗標 false 的 RED case 仍 8/8 全紅，150ms 約有 150 倍餘裕；以後若遇到
        // 間歇性 flake，先查上面 F2 提到的合流時序假設是否成立，不要直接調大這個常數
        // （PR #120 R1 F3）。
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertGreaterThan(
            offlineCallCount.withLock { $0 }, 0,
            "離線 stub 應該至少被呼叫過一次，確認這條測試真的走了離線重試路徑"
        )
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

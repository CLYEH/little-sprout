import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-348：登入落點偶發「伺服器發生問題」的回歸測試。
///
/// 根因（kong／PostgREST 對照實驗，見 LS-348 handoff）：登入落點的第一批 REST 請求
/// （`app_settings`／`profiles`／`families` 三支併發）帶的是**剛簽發**的使用者 JWT，PostgREST
/// 偶發以 `401 {"code":"PGRST303","message":"JWT issued at future"}`（kong log 79 bytes）拒收
/// 其中最早抵達的一兩支，同一秒稍後抵達、帶同一把 token 的請求卻是 200——是伺服器端判定 `iat`
/// 的暫態，不是 client 端「token 尚未套用」（未帶使用者 token 的請求會是 `42501 permission
/// denied`，194 bytes，錯誤碼與位元組數皆不符）。修法：這三支落點請求遇到 `PGRST303` 以同一個
/// 呼叫重送一次（`retryingOnceOnTransientJWTRejection`），而 `PGRST303` 本身歸
/// `.retryableSystem`（`AppError.map`），不再落 `.server` 顯示「伺服器發生問題」。
///
/// 全部走 `MockURLProtocol`（真正的 SDK 編碼／解碼與錯誤映射，不打真網路），同
/// `SupabaseEULAAPIClientTests` 的模式。
final class TransientJWTRetryTests: XCTestCase {
    private let userID = UUID(uuidString: "34834834-8348-3483-4834-834834834834")!

    /// PostgREST v14 對 `iat` 超前伺服器時鐘 30 秒以上的 JWT 回的原文（本機容器實測，body 79 bytes，
    /// 與 LS-348 QA 觀察到的 kong log `401 79` 位元組數一致）。
    private static let jwtIssuedAtFutureBody = Data("""
    {"code":"PGRST303","details":null,"hint":null,"message":"JWT issued at future"}
    """.utf8)

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    // MARK: - 範圍 1：token 套用時機（票文原假設「app_settings 先於 token 就緒」的反證）

    /// 票文原本懷疑 EULA 版本查詢在 access token 套用到 client 之前就發出。這支釘住實際行為：
    /// `verifyEmailOTP` 回傳時 SDK 已把 session 寫進儲存（`AuthClient._verifyOTP` 先
    /// `sessionManager.update` 再 return），`AuthStore.session` 在那之後才被設值、才觸發
    /// `AuthenticatedGate` 的 `.task(id:)`——落點第一支 REST 請求一定帶使用者 token。日後若有人
    /// 改動登入流程讓 REST 請求可能早於 session 落地，這支會紅。
    func test_firstRestRequestAfterVerifyOTP_carriesUserAccessToken() async throws {
        let seenAuthorization = OSAllocatedUnfairLock<String?>(initialState: nil)
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/verify" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "ls348@example.com")
                )
            }
            XCTAssertEqual(request.url?.path, "/rest/v1/app_settings")
            seenAuthorization.withLock { $0 = request.value(forHTTPHeaderField: "Authorization") }
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {"eula_version":"2026-09-05-draft"}
            """.utf8))
        }
        _ = try await SupabaseAuthService(client: client).verifyEmailOTP(email: "ls348@example.com", token: "123456")

        _ = try await SupabaseEULAAPIClient(client: client).fetchCurrentVersion()

        XCTAssertEqual(
            seenAuthorization.withLock { $0 }, "Bearer fake-access-token",
            "落點第一支 REST 請求必須帶 verify 回來的使用者 access token，不是 anon key"
        )
    }

    // MARK: - 範圍 2：PGRST303 以同一呼叫重送一次

    func test_fetchCurrentVersion_jwtIssuedAtFutureOnce_retriesAndSucceeds() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/app_settings")
            let attempt = calls.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                return MockURLProtocol.StubResponse(statusCode: 401, body: Self.jwtIssuedAtFutureBody)
            }
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {"eula_version":"2026-09-05-draft"}
            """.utf8))
        }

        let version = try await SupabaseEULAAPIClient(client: client).fetchCurrentVersion()

        XCTAssertEqual(version, "2026-09-05-draft", "PGRST303 暫態後重送一次應拿到版本，不是整頁錯誤")
        XCTAssertEqual(calls.withLock { $0 }, 2, "應該剛好重送一次")
    }

    func test_fetchAcceptedVersion_jwtIssuedAtFutureOnce_retriesAndSucceeds() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/profiles")
            let attempt = calls.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                return MockURLProtocol.StubResponse(statusCode: 401, body: Self.jwtIssuedAtFutureBody)
            }
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {"eula_accepted_version":"2026-09-05-draft"}
            """.utf8))
        }

        let version = try await SupabaseEULAAPIClient(client: client).fetchAcceptedVersion(userID: userID)

        XCTAssertEqual(version, "2026-09-05-draft", "PGRST303 暫態後重送一次應拿到已同意版本")
        XCTAssertEqual(calls.withLock { $0 }, 2, "應該剛好重送一次")
    }

    /// kong log 09-17 18:01:28／09-19 16:08:27 兩次事故裡 `families` 也吃到同一個 `401 79`——
    /// 同一批落點請求、同一個根因，家庭查詢失敗一樣會整頁擋住登入（`familyGate` 的重試畫面）。
    func test_fetchMyFamily_jwtIssuedAtFutureOnce_retriesAndSucceeds() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/families")
            let attempt = calls.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                return MockURLProtocol.StubResponse(statusCode: 401, body: Self.jwtIssuedAtFutureBody)
            }
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }

        let family = try await SupabaseFamilyAPIClient(client: client).fetchMyFamily()

        XCTAssertNil(family, "PGRST303 暫態後重送一次應得到查詢結果（新帳號＝沒有家庭），不是錯誤")
        XCTAssertEqual(calls.withLock { $0 }, 2, "應該剛好重送一次")
    }

    /// 只重送一次：伺服器時鐘若真的持續偏差，第二次仍失敗就照實往上拋（fail loud），不無限重試；
    /// 拋出的分類是 `.retryableSystem`（「請再試一次。」＋重試鈕），不是 `.server`「伺服器發生問題」。
    func test_fetchCurrentVersion_jwtIssuedAtFutureTwice_throwsRetryableSystemAfterSingleRetry() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let client = TestSupabaseClient.make { _ in
            calls.withLock { $0 += 1 }
            return MockURLProtocol.StubResponse(statusCode: 401, body: Self.jwtIssuedAtFutureBody)
        }

        do {
            _ = try await SupabaseEULAAPIClient(client: client).fetchCurrentVersion()
            XCTFail("連續兩次 PGRST303 應該要 throw")
        } catch let error as AppError {
            guard case .retryableSystem(_, let code) = error else {
                return XCTFail("PGRST303 應映射為 .retryableSystem，實際是 \(error)")
            }
            XCTAssertEqual(code, "PGRST303")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
        XCTAssertEqual(calls.withLock { $0 }, 2, "只重送一次，不得無限重試")
    }

    /// 重送只針對 PGRST303：真正的權限不足（例如未帶使用者 token 的 `42501`）重送同一個呼叫
    /// 不會變成功，不得白打第二次。
    func test_fetchCurrentVersion_permissionDenied401_doesNotRetry() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let client = TestSupabaseClient.make { _ in
            calls.withLock { $0 += 1 }
            return MockURLProtocol.StubResponse(statusCode: 401, body: Data("""
            {"code":"42501","details":null,"hint":null,"message":"permission denied for table app_settings"}
            """.utf8))
        }

        do {
            _ = try await SupabaseEULAAPIClient(client: client).fetchCurrentVersion()
            XCTFail("42501 應該要 throw")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("42501 應映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "42501")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
        XCTAssertEqual(calls.withLock { $0 }, 1, "非 PGRST303 的錯誤不得重送")
    }
}

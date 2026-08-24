import Auth
import Foundation
@testable import LittleSprout
import PostgREST
import XCTest

/// `AppError.map` 是 k2Mw4 四層錯誤文法在 client 端唯一的分類入口，這裡逐一釘住
/// 每一類的判斷依據（HTTP 狀態碼／Postgres SQLSTATE／本專案自訂 LS0xx），
/// 這條規則變了（例如哪個狀態碼算可重試）測試會跟著失敗，而不是悄悄改變 UI 的行為分類。
final class AppErrorTests: XCTestCase {
    // MARK: - 系統層

    func test_map_urlError_isNetwork() {
        let error = URLError(.notConnectedToInternet)
        guard case .network = AppError.map(error) else {
            return XCTFail("URLError 應映射為 .network")
        }
    }

    func test_map_alreadyAppError_passesThroughUnchanged() {
        let original = AppError.rejected(message: "已經拒絕", code: "custom")
        guard case .rejected(let message, let code) = AppError.map(original) else {
            return XCTFail("已經是 AppError 的錯誤不該被重新分類")
        }
        XCTAssertEqual(message, "已經拒絕")
        XCTAssertEqual(code, "custom")
    }

    func test_map_unrecognizedError_fallsBackToServer() {
        struct SomeOtherError: Error {}
        guard case .server = AppError.map(SomeOtherError()) else {
            return XCTFail("辨認不出來的錯誤要 fail loud 落在 .server，不能被靜默吞掉")
        }
    }

    // MARK: - AuthError

    func test_map_authError_sessionMissing_isRejected() {
        guard case .rejected = AppError.map(AuthError.sessionMissing) else {
            return XCTFail(".sessionMissing 代表未登入，屬於「被拒」而非可重試")
        }
    }

    func test_map_authError_api401_isRejected() {
        let error = makeAuthAPIError(statusCode: 401)
        guard case .rejected = AppError.map(error) else {
            return XCTFail("401 應映射為 .rejected")
        }
    }

    func test_map_authError_api403_isRejected() {
        let error = makeAuthAPIError(statusCode: 403)
        guard case .rejected = AppError.map(error) else {
            return XCTFail("403 應映射為 .rejected")
        }
    }

    func test_map_authError_api429_isValidationRetryable() {
        let error = makeAuthAPIError(statusCode: 429)
        guard case .validationRetryable = AppError.map(error) else {
            return XCTFail("429（頻率限制）應映射為 .validationRetryable——換個時間點再試就可能成功")
        }
    }

    func test_map_authError_api400_isValidationRetryable() {
        let error = makeAuthAPIError(statusCode: 400, errorCode: .otpExpired)
        guard case .validationRetryable(_, let code) = AppError.map(error) else {
            return XCTFail("400（例如 OTP 過期）應映射為 .validationRetryable")
        }
        XCTAssertEqual(code, "otp_expired")
    }

    func test_map_authError_api500_isServer() {
        let error = makeAuthAPIError(statusCode: 500)
        guard case .server = AppError.map(error) else {
            return XCTFail("5xx 應映射為 .server")
        }
    }

    func test_map_authError_pkceFailure_isRejected() {
        let error = AuthError.pkceGrantCodeExchange(message: "bad state")
        guard case .rejected = AppError.map(error) else {
            return XCTFail("PKCE 流程失敗需要重新走一次登入流程，屬於 .rejected 而非可重試")
        }
    }

    // MARK: - PostgrestError

    func test_map_postgrestError_customJoinApprovalCode_isValidationRetryable() {
        // LS012：supabase/migrations/20260823010000_join_approval.sql——邀請碼使用次數已用完。
        let error = PostgrestError(code: "LS012", message: "邀請碼的使用次數已用完")
        guard case .validationRetryable(let message, let code) = AppError.map(error) else {
            return XCTFail("自訂 LS0xx 碼應映射為 .validationRetryable")
        }
        XCTAssertEqual(message, "邀請碼的使用次數已用完")
        XCTAssertEqual(code, "LS012")
    }

    func test_map_postgrestError_insufficientPrivilege_isRejected() {
        let error = PostgrestError(code: "42501", message: "只有該家庭的 owner 能建立邀請碼")
        guard case .rejected(_, let code) = AppError.map(error) else {
            return XCTFail("42501（insufficient_privilege）應映射為 .rejected")
        }
        XCTAssertEqual(code, "42501")
    }

    func test_map_postgrestError_uniqueViolation_isValidationRetryable() {
        let error = PostgrestError(code: "23505", message: "duplicate key value")
        guard case .validationRetryable = AppError.map(error) else {
            return XCTFail("23505（unique_violation）應映射為 .validationRetryable")
        }
    }

    func test_map_postgrestError_unrecognizedCode_isServer() {
        let error = PostgrestError(code: "XX000", message: "internal error")
        guard case .server = AppError.map(error) else {
            return XCTFail("辨認不出來的 SQLSTATE 要 fail loud 落在 .server")
        }
    }

    func test_map_postgrestError_unknownLSCode_isServer() {
        // LS999 不在 LSErrorCode 裡：後端新增了碼、Swift 還沒列舉時，必須 fail loud 落在 .server
        // （逼呼叫端至少顯示「發生錯誤」），不能被「開頭是 LS」這種前綴比對悄悄歸進可重試。
        // 與 error-codes-check gate 互補：gate 擋 API.md 表裡有而 Swift 沒有的碼，這裡釘住
        // 萬一漏網（例如後端直接 raise 了表裡沒有的碼）時的行為（LS-54）。
        let error = PostgrestError(code: "LS999", message: "unlisted custom code")
        guard case .server(_, let code) = AppError.map(error) else {
            return XCTFail("未列舉的 LS 碼應映射為 .server，實際是不同的分類")
        }
        XCTAssertEqual(code, "LS999")
    }

    func test_map_postgrestError_missingCode_isServer() {
        let error = PostgrestError(code: nil, message: "unexpected")
        guard case .server = AppError.map(error) else {
            return XCTFail("沒有 code 的 PostgrestError 應映射為 .server")
        }
    }

    func test_map_postgrestError_pgrst301_isRejected() {
        let error = PostgrestError(code: "PGRST301", message: "JWT expired")
        guard case .rejected(_, let code) = AppError.map(error) else {
            return XCTFail("PGRST301（JWT 過期）應映射為 .rejected，實際是不同的分類")
        }
        XCTAssertEqual(code, "PGRST301")
    }

    // MARK: - HTTPError（PostgrestError 解不出來的非 JSON 錯誤回應，例如反向代理的 502 HTML 頁）

    func test_map_httpError_500_isServer() {
        let error = makeHTTPError(statusCode: 502, body: "<html>Bad Gateway</html>")
        guard case .server = AppError.map(error) else {
            return XCTFail("502 應映射為 .server（PostgrestError 解不出來也要看狀態碼分類）")
        }
    }

    func test_map_httpError_401_isRejected() {
        let error = makeHTTPError(statusCode: 401, body: "")
        guard case .rejected = AppError.map(error) else {
            return XCTFail("401 應映射為 .rejected")
        }
    }

    // MARK: - LSErrorCode 逐碼列舉（docs/API.md §5；LS-49 PR #63 review F4）

    func test_lsErrorCode_tierClassification_isExhaustiveAndCorrect() {
        // 新加一個 LS0xx code 卻忘記放進下面任一組時，聯集會少一個、跟 CaseIterable 全集
        // 對不上，這條測試就會失敗——逼著新碼被明確歸類，不能靠字串前綴悄悄矇混過去。
        let expectedRejected: Set<LSErrorCode> = [
            .familyMustHaveOwner,
            .storageQuotaExceeded,
            .alreadyMember,
            .alreadyHasPendingRequest,
            .requestNotFoundOrProcessed,
            .diaryNotFoundOrDeleted,
            .diaryNotEditableByCaller,
            .albumNotFound,
            .commentNotFound
        ]
        let expectedValidationRetryable: Set<LSErrorCode> = [
            .inviteCodeNotFound,
            .inviteCodeExpired,
            .inviteCodeExhausted,
            .inviteCodeGenerationCollision,
            .inviteParamsInvalid,
            .timelineCursorIncomplete
        ]

        XCTAssertEqual(expectedRejected.union(expectedValidationRetryable), Set(LSErrorCode.allCases))
        XCTAssertTrue(expectedRejected.isDisjoint(with: expectedValidationRetryable))

        for code in expectedRejected {
            XCTAssertEqual(code.tier, .rejected, "\(code.rawValue) 應該是 .rejected")
        }
        for code in expectedValidationRetryable {
            XCTAssertEqual(code.tier, .validationRetryable, "\(code.rawValue) 應該是 .validationRetryable")
        }
    }

    func test_map_postgrestError_alreadyMember_isRejected() {
        // LS013：重試同一個 request_join 呼叫永遠不會成功（已經是成員了），
        // 這是本票最初把「所有 LS0xx 都當 validationRetryable」判斷錯的那個案例。
        let error = PostgrestError(code: "LS013", message: "你已經是這個家庭的成員")
        guard case .rejected(_, let code) = AppError.map(error) else {
            return XCTFail("LS013 應映射為 .rejected，實際是不同的分類")
        }
        XCTAssertEqual(code, "LS013")
    }

    func test_map_postgrestError_familyMustHaveOwner_isRejected() {
        let error = PostgrestError(code: "LS001", message: "家庭必須至少保留一位 owner")
        guard case .rejected(_, let code) = AppError.map(error) else {
            return XCTFail("LS001 應映射為 .rejected")
        }
        XCTAssertEqual(code, "LS001")
    }

    // MARK: - Helpers

    private func makeHTTPError(statusCode: Int, body: String) -> HTTPError {
        HTTPError(
            data: Data(body.utf8),
            response: HTTPURLResponse(
                url: URL(string: "https://test.supabase.co/rest/v1/families")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    private func makeAuthAPIError(statusCode: Int, errorCode: ErrorCode = .unknown) -> AuthError {
        .api(
            message: "test message",
            errorCode: errorCode,
            underlyingData: Data(),
            underlyingResponse: HTTPURLResponse(
                url: URL(string: "https://test.supabase.co/auth/v1/token")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

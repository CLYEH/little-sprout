import Foundation
@testable import LittleSprout
import XCTest

/// `JoinCodeView`（06／06b／06c）依 `FamilyStore.requestJoinState` 決定顯示哪一態——過期
/// （`LS011`）與次數用盡（`LS012`）各自要能被獨立識別出來，其餘錯誤落回一般錯誤列。見
/// `JoinCodeFormPhase` 文件註解。
final class JoinCodePhaseTests: XCTestCase {
    func test_idle_isIdle() {
        XCTAssertEqual(JoinCodeFormPhase(requestJoinState: .idle), .idle)
    }

    func test_submitting_isSubmitting() {
        XCTAssertEqual(JoinCodeFormPhase(requestJoinState: .submitting), .submitting)
    }

    func test_expiredCode_isExpired() {
        let error = AppError.validationRetryable(message: "過期", code: LSErrorCode.inviteCodeExpired.rawValue)
        XCTAssertEqual(JoinCodeFormPhase(requestJoinState: .failure(error)), .expired)
    }

    func test_exhaustedCode_isExhausted() {
        let error = AppError.validationRetryable(message: "用完", code: LSErrorCode.inviteCodeExhausted.rawValue)
        XCTAssertEqual(JoinCodeFormPhase(requestJoinState: .failure(error)), .exhausted)
    }

    func test_codeNotFound_isGenericError_notExpiredOrExhausted() {
        let error = AppError.validationRetryable(message: "碼不存在", code: LSErrorCode.inviteCodeNotFound.rawValue)
        XCTAssertEqual(JoinCodeFormPhase(requestJoinState: .failure(error)), .genericError(error))
    }

    func test_networkFailure_isGenericError() {
        let error = AppError.network(message: "offline")
        XCTAssertEqual(JoinCodeFormPhase(requestJoinState: .failure(error)), .genericError(error))
    }

    func test_success_isIdle_notError() {
        // 成功之後 `JoinCodeView` 會導頁離開，`requestJoinState` 本身停在 `.success` 不影響
        // 顯示——這裡確認 `.success` 不會被誤判成任何一種錯誤態。
        XCTAssertEqual(JoinCodeFormPhase(requestJoinState: .success), .idle)
    }

    func test_isError_trueOnlyForExpiredExhaustedOrGenericError() {
        XCTAssertFalse(JoinCodeFormPhase.idle.isError)
        XCTAssertFalse(JoinCodeFormPhase.submitting.isError)
        XCTAssertTrue(JoinCodeFormPhase.expired.isError)
        XCTAssertTrue(JoinCodeFormPhase.exhausted.isError)
        XCTAssertTrue(JoinCodeFormPhase.genericError(.network(message: "offline")).isError)
    }
}

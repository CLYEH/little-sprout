import Foundation
@testable import LittleSprout
import XCTest

/// 06d 輪詢 `get_my_join_request` 之後的狀態機（票文驗收「join-request 狀態機單元測試 ≥6
/// 條」）——見 `JoinWaitingPhase` 文件註解：拒絕、撤回、查無此筆（例如 owner 撤銷了邀請碼，
/// cascade 掉這筆 pending 申請）對申請人而言結果相同，都要回三岔路、沒有任何殘留權限。
final class JoinWaitingPhaseTests: XCTestCase {
    private let requestID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private let familyID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    private func makeRequest(status: JoinRequestStatus, requestID: UUID? = nil) -> MyJoinRequest {
        MyJoinRequest(
            requestID: requestID ?? self.requestID,
            familyID: familyID,
            familyName: "陳家",
            status: status,
            createdAt: Date(),
            resolvedAt: status == .pending ? nil : Date()
        )
    }

    func test_pending_sameRequestID_isStillWaiting() {
        let result = makeRequest(status: .pending)

        XCTAssertEqual(JoinWaitingPhase.pollOutcome(for: result, expectedRequestID: requestID), .stillWaiting)
    }

    func test_approved_sameRequestID_isApproved() {
        let result = makeRequest(status: .approved)

        XCTAssertEqual(JoinWaitingPhase.pollOutcome(for: result, expectedRequestID: requestID), .approved)
    }

    func test_rejected_sameRequestID_returnsToFork() {
        let result = makeRequest(status: .rejected)

        XCTAssertEqual(JoinWaitingPhase.pollOutcome(for: result, expectedRequestID: requestID), .returnToFork)
    }

    func test_withdrawn_sameRequestID_returnsToFork() {
        // 例如另一台裝置上撤回了同一筆申請——這裡輪詢到的是「別人幫我撤回了」，行為與
        // 自己按「撤回這次申請」相同。
        let result = makeRequest(status: .withdrawn)

        XCTAssertEqual(JoinWaitingPhase.pollOutcome(for: result, expectedRequestID: requestID), .returnToFork)
    }

    func test_nilResult_returnsToFork() {
        // 例如 owner 撤銷了底下的邀請碼，cascade 刪掉這筆 pending 申請（docs/API.md §7
        // 設計上的硬決定第 3 點）——`get_my_join_request` 從沒有 pending 落回「最近一筆已處理
        // 的」，若這位申請人也從未有過其他已處理的申請，就會是 0 列（nil）。
        XCTAssertEqual(JoinWaitingPhase.pollOutcome(for: nil, expectedRequestID: requestID), .returnToFork)
    }

    func test_mismatchedRequestID_returnsToFork() {
        // `get_my_join_request` 沒有 pending 時回「最近一筆已處理的」——若那不是這次等待的這筆
        // （理論上不會發生，但不假設它不會），不能誤採信成這筆的結果。
        let unrelatedRequestID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let result = makeRequest(status: .approved, requestID: unrelatedRequestID)

        XCTAssertEqual(JoinWaitingPhase.pollOutcome(for: result, expectedRequestID: requestID), .returnToFork)
    }
}

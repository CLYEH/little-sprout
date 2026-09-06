import Foundation
@testable import LittleSprout
import os

/// LS-193：`DeleteAccountFlowModel` 測試用假 `AccountAPIClient`——不打真網路，用可設定的
/// handler 決定 `deleteMyAccount()`／`finalizeAccountDeletion()` 怎麼表現，同
/// `StubFamilyAPIClient`／`StubAuthService` 的既有模式（lock 保護的可變 handler）。
final class StubAccountAPIClient: AccountAPIClient, @unchecked Sendable {
    typealias DeleteMyAccountHandler = @Sendable () async throws -> DeleteMyAccountOutcome
    typealias FinalizeHandler = @Sendable () async throws -> Void

    enum StubError: Error {
        case unconfigured
    }

    private struct Box {
        var deleteMyAccountHandler: DeleteMyAccountHandler = { throw StubError.unconfigured }
        var deleteMyAccountCallCount = 0
        var finalizeHandler: FinalizeHandler = { throw StubError.unconfigured }
        var finalizeCallCount = 0
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var deleteMyAccountCallCount: Int {
        box.withLock { $0.deleteMyAccountCallCount }
    }

    var finalizeCallCount: Int {
        box.withLock { $0.finalizeCallCount }
    }

    func setDeleteMyAccountHandler(_ handler: @escaping DeleteMyAccountHandler) {
        box.withLock { $0.deleteMyAccountHandler = handler }
    }

    func setFinalizeHandler(_ handler: @escaping FinalizeHandler) {
        box.withLock { $0.finalizeHandler = handler }
    }

    func deleteMyAccount() async throws -> DeleteMyAccountOutcome {
        box.withLock { $0.deleteMyAccountCallCount += 1 }
        let handler = box.withLock { $0.deleteMyAccountHandler }
        return try await handler()
    }

    func finalizeAccountDeletion() async throws {
        box.withLock { $0.finalizeCallCount += 1 }
        let handler = box.withLock { $0.finalizeHandler }
        try await handler()
    }
}

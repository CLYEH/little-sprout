import Foundation
@testable import LittleSprout
import os

/// `EULAStore` 測試用假 `EULAAPIClient`——不打真網路，用可設定的 handler 決定各方法的表現
/// （同 `StubTimelineAPIClient` 的模式，見該檔）。
final class StubEULAAPIClient: EULAAPIClient, @unchecked Sendable {
    typealias FetchCurrentVersionHandler = @Sendable () async throws -> String
    typealias FetchAcceptedVersionHandler = @Sendable (UUID) async throws -> String?
    typealias AcceptEULAHandler = @Sendable (String) async throws -> Void

    private struct Box {
        var fetchCurrentVersionHandler: FetchCurrentVersionHandler = { "2026-09-05-draft" }
        var fetchAcceptedVersionHandler: FetchAcceptedVersionHandler = { _ in nil }
        var acceptEULAHandler: AcceptEULAHandler = { _ in }
        var acceptEULACalls: [String] = []
        /// LS-190 R2 m1：`EULAStoreTests` 用來斷言「`guard !isSubmitting` 真的擋掉了重複呼叫」
        /// ——沒有這個計數器測不出「guard 生效」跟「handler 本身很快回來」的差別。
        var fetchCurrentVersionCallCount = 0
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var acceptEULACalls: [String] {
        box.withLock { $0.acceptEULACalls }
    }

    var fetchCurrentVersionCallCount: Int {
        box.withLock { $0.fetchCurrentVersionCallCount }
    }

    func setFetchCurrentVersionHandler(_ handler: @escaping FetchCurrentVersionHandler) {
        box.withLock { $0.fetchCurrentVersionHandler = handler }
    }

    func setFetchAcceptedVersionHandler(_ handler: @escaping FetchAcceptedVersionHandler) {
        box.withLock { $0.fetchAcceptedVersionHandler = handler }
    }

    func setAcceptEULAHandler(_ handler: @escaping AcceptEULAHandler) {
        box.withLock { $0.acceptEULAHandler = handler }
    }

    func fetchCurrentVersion() async throws -> String {
        box.withLock { $0.fetchCurrentVersionCallCount += 1 }
        let handler = box.withLock { $0.fetchCurrentVersionHandler }
        return try await handler()
    }

    func fetchAcceptedVersion(userID: UUID) async throws -> String? {
        let handler = box.withLock { $0.fetchAcceptedVersionHandler }
        return try await handler(userID)
    }

    func acceptEULA(version: String) async throws {
        box.withLock { $0.acceptEULACalls.append(version) }
        let handler = box.withLock { $0.acceptEULAHandler }
        try await handler(version)
    }
}

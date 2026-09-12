import Foundation
@testable import LittleSprout
import os

/// `PushNotificationStore` 測試用假 `PushDeviceTokenAPIClient`——不打真網路，記錄每次呼叫的
/// 參數供斷言去重／重送邏輯（同 `StubEULAAPIClient` 的模式，見該檔）。
final class StubPushDeviceTokenAPIClient: PushDeviceTokenAPIClient, @unchecked Sendable {
    typealias RegisterHandler = @Sendable (String, String) async throws -> Void

    private struct Box {
        var registerHandler: RegisterHandler = { _, _ in }
        /// 每次呼叫都記錄（不論 handler 成功或失敗）——測「有沒有真的打了 RPC」用
        /// `callCount`；測「送出去的內容」用這個陣列本身。
        var calls: [(token: String, platform: String)] = []
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var registeredTokens: [String] {
        box.withLock { $0.calls.map(\.token) }
    }

    var registerCallCount: Int {
        box.withLock { $0.calls.count }
    }

    func setRegisterHandler(_ handler: @escaping RegisterHandler) {
        box.withLock { $0.registerHandler = handler }
    }

    func registerDeviceToken(token: String, platform: String) async throws {
        box.withLock { $0.calls.append((token, platform)) }
        let handler = box.withLock { $0.registerHandler }
        try await handler(token, platform)
    }
}

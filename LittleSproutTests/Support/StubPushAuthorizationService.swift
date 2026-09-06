import Foundation
@testable import LittleSprout
import os
import UserNotifications

/// `PushNotificationStore` 測試用假 `PushAuthorizationService`——不會真的跳系統對話框，用可
/// 設定的 handler 決定各方法的表現（同 `StubEULAAPIClient` 的模式，見該檔）。
final class StubPushAuthorizationService: PushAuthorizationService, @unchecked Sendable {
    typealias RequestAuthorizationHandler = @Sendable () async throws -> Bool

    private struct Box {
        var status: UNAuthorizationStatus = .notDetermined
        var requestAuthorizationHandler: RequestAuthorizationHandler = { true }
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    init(status: UNAuthorizationStatus = .notDetermined) {
        box.withLock { $0.status = status }
    }

    func setStatus(_ status: UNAuthorizationStatus) {
        box.withLock { $0.status = status }
    }

    func setRequestAuthorizationHandler(_ handler: @escaping RequestAuthorizationHandler) {
        box.withLock { $0.requestAuthorizationHandler = handler }
    }

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        box.withLock { $0.status }
    }

    func requestAuthorization() async throws -> Bool {
        let handler = box.withLock { $0.requestAuthorizationHandler }
        return try await handler()
    }
}

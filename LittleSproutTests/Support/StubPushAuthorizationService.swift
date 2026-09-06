import Foundation
@testable import LittleSprout
import os
import UserNotifications

/// `PushNotificationStore` 測試用假 `PushAuthorizationService`——不會真的跳系統對話框，用可
/// 設定的 handler 決定各方法的表現（同 `StubEULAAPIClient` 的模式，見該檔）。
final class StubPushAuthorizationService: PushAuthorizationService, @unchecked Sendable {
    typealias RequestAuthorizationHandler = @Sendable () async throws -> Bool
    /// merge-review R1 m2 測試用：讓 `currentAuthorizationStatus()` 卡在呼叫端指定的地方
    /// （通常是 `await gate.wait()`），藉此在真正的 await 中間精準取消外層 `Task`——不設定時
    /// 直接回傳 `status`，跟原本行為一樣。
    typealias CurrentAuthorizationStatusHandler = @Sendable () async -> UNAuthorizationStatus

    private struct Box {
        var status: UNAuthorizationStatus = .notDetermined
        var requestAuthorizationHandler: RequestAuthorizationHandler = { true }
        var currentAuthorizationStatusHandler: CurrentAuthorizationStatusHandler?
        /// merge-review R1 M1：`registerForRemoteNotifications()` 被抽成協定方法之後的呼叫次數
        /// ——沒有這個就無法斷言「冷啟動／換帳號有沒有真的觸發註冊」。
        var registerForRemoteNotificationsCallCount = 0
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    init(status: UNAuthorizationStatus = .notDetermined) {
        box.withLock { $0.status = status }
    }

    var registerForRemoteNotificationsCallCount: Int {
        box.withLock { $0.registerForRemoteNotificationsCallCount }
    }

    func setStatus(_ status: UNAuthorizationStatus) {
        box.withLock { $0.status = status }
    }

    func setRequestAuthorizationHandler(_ handler: @escaping RequestAuthorizationHandler) {
        box.withLock { $0.requestAuthorizationHandler = handler }
    }

    func setCurrentAuthorizationStatusHandler(_ handler: @escaping CurrentAuthorizationStatusHandler) {
        box.withLock { $0.currentAuthorizationStatusHandler = handler }
    }

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        let handler = box.withLock { $0.currentAuthorizationStatusHandler }
        if let handler {
            return await handler()
        }
        return box.withLock { $0.status }
    }

    func requestAuthorization() async throws -> Bool {
        let handler = box.withLock { $0.requestAuthorizationHandler }
        return try await handler()
    }

    func registerForRemoteNotifications() async {
        box.withLock { $0.registerForRemoteNotificationsCallCount += 1 }
    }
}

import UserNotifications

/// LS-217：`UNUserNotificationCenter` 的協定包裝——單元測試不能真的觸發系統權限對話框
/// （CI／模擬器沒有人手動點「允許」，且每次跑到的授權狀態不可控、無法重複），因此把「查目前
/// 授權狀態」／「跟系統要授權」抽成協定。`PushNotificationStore` 只依賴這個協定；生產路徑用
/// `SystemPushAuthorizationService`，`#Preview`／`TapTargetGateHarness` 用
/// `Support/PreviewPushAPIClient.swift` 的假實作，單元測試用
/// `LittleSproutTests/Support/StubPushAuthorizationService.swift`——同 `EULAAPIClient`／
/// `SafetyAPIClient` 既有的分層慣例（協定＋生產實作＋預覽假實作＋測試假實作四件套）。
protocol PushAuthorizationService: Sendable {
    /// 目前系統授權狀態（`UNUserNotificationCenter.current().notificationSettings()`）。
    func currentAuthorizationStatus() async -> UNAuthorizationStatus

    /// 跳出系統對話框要求 `.alert`／`.sound`／`.badge` 三項授權（票文範圍 2）；回傳使用者是否
    /// 允許。`design/littlesprout.pen` `FeqWk`（系統對話框示意）票文明講「不實作」——這裡呼叫的
    /// 就是系統原生對話框本身，app 不能、也不需要自己畫一份。
    func requestAuthorization() async throws -> Bool
}

/// 生產路徑：直接轉呼叫 `UNUserNotificationCenter.current()`。
struct SystemPushAuthorizationService: PushAuthorizationService {
    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
}

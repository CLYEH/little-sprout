import Foundation
import Observation
import os
import UserNotifications

/// 推播權限與裝置 token 註冊（LS-217）的 `@Observable` 狀態管理——同 `EULAStore` 之於
/// `EULAAPIClient` 的角色：把 `PushAuthorizationService`／`PushDeviceTokenAPIClient` 包成
/// `AuthenticatedRootView`／`SettingsView` 能直接讀狀態驅動重繪的 store，隨 app 存活
/// （`LittleSproutApp` 建一次，見該檔文件註解）。
@MainActor
@Observable
final class PushNotificationStore {
    private let authorizationService: PushAuthorizationService
    private let deviceTokenAPIClient: PushDeviceTokenAPIClient
    /// merge-review R1 m1：`submitTokenIfNeeded` 的去重 guard（`UserDefaults`）跨一個 `await`，
    /// `AppDelegate` 每次 `didRegisterForRemoteNotificationsWithDeviceToken` 都開新 `Task`——
    /// 連續兩次回呼會在 guard 通過後、`markSubmitted` 之前互相追上，重複打 RPC。這裡記錄「正在
    /// 送出中」的 (userID, tokenHex) 組合；store 是 `@MainActor`，插入與檢查之間沒有 `await`，
    /// 是原子的。
    private var inFlightSubmissions: Set<String> = []
    /// merge-review R2 m3：`didFailToRegister` 原本只在 `#if DEBUG print(...)`，Release／
    /// TestFlight build 完全靜默——`register_device_token` 打不通（RLS、離線）或 APNs 註冊失敗
    /// 時沒有任何痕跡，而這正是「使用者說收不到推播」最可能的成因。改用 `os.Logger` 讓 Release
    /// 也留得下紀錄（`subsystem` 用 bundle id，找不到時退回硬編字面值——測試環境的
    /// `Bundle.main.bundleIdentifier` 未必是 app 的 bundle id，但 log 訊息本身不影響測試）。
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.leoyeh.littlesprout", category: "push"
    )

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// `AuthenticatedRootView` 的 `.fullScreenCover(isPresented:)` 綁這個——同
    /// `FamilyStore.showsChildOnboarding` 既有的「store 算好要不要顯示、View 只負責綁定」分工
    /// （見該屬性文件註解）。
    private(set) var showsPreprompt = false

    init(authorizationService: PushAuthorizationService, deviceTokenAPIClient: PushDeviceTokenAPIClient) {
        self.authorizationService = authorizationService
        self.deviceTokenAPIClient = deviceTokenAPIClient
    }

    /// `AuthenticatedRootView` 的 `.task(id: authStore.session?.userID)` 呼叫——查目前系統
    /// 授權狀態，並依 `PushPrepromptPolicy` 判斷「登入後首次進時間軸」是否該自動顯示前置頁
    /// （票文範圍 1）。這條路徑同時是冷啟動與「同一行程內換帳號」唯一會跑到的重新整理路徑
    /// （`.task(id:)` 綁 `authStore.session?.userID`，換帳號會取消舊 task、開新的一次）——
    /// merge-review R1 M1：已授權／provisional 時必須重新呼叫 `registerForRemoteNotifications()`
    /// 讓系統再送一次裝置 token 回呼，否則 (a) token 輪替後永遠不會重送、(b) 換帳號後這支裝置
    /// 會持續收到前一位使用者家庭的推播（`docs/API.md:767-770`）。去重邏輯仍在
    /// `submitTokenIfNeeded` 那一層——merge-review R2 M2：`PushDeviceTokenSubmissionRecord`
    /// 改成裝置層級單一綁定紀錄後，任何帳號切換（含 A→B→A 切回）都會視為未送過，這裡
    /// 只負責觸發。
    func refreshForEnteringApp(userID: UUID) async {
        let status = await authorizationService.currentAuthorizationStatus()
        // merge-review R1 m2：`.task(id:)` 換帳號時會取消舊 task，但
        // `UNUserNotificationCenter.notificationSettings()` 不因取消提前返回——取消後回來的
        // 這一份結果屬於「上一位使用者」查詢當下的狀態，寫入會覆蓋掉新使用者已經算好的判斷。
        guard !Task.isCancelled else { return }
        authorizationStatus = status
        showsPreprompt = PushPrepromptPolicy.shouldPresent(
            authorizationStatus: status,
            hasShownBefore: PushPrepromptDisplayRecord.hasShown(userID: userID)
        )
        guard status == .authorized || status == .provisional else { return }
        await authorizationService.registerForRemoteNotifications()
    }

    /// 每次 App 進前景重讀狀態（票文範圍 2）——不影響 `showsPreprompt`（前置頁只在「登入後
    /// 首次進場」判斷一次，見 `refreshForEnteringApp`）；已授權時重新呼叫
    /// `registerForRemoteNotifications()`，讓系統再送一次 `didRegisterForRemoteNotifications
    /// WithDeviceToken`——去重邏輯在 `submitTokenIfNeeded` 那一層，這裡只負責觸發。
    func refreshOnForeground(userID: UUID) async {
        authorizationStatus = await authorizationService.currentAuthorizationStatus()
        guard authorizationStatus == .authorized else { return }
        await authorizationService.registerForRemoteNotifications()
    }

    /// 前置頁關閉（不論是「開啟通知」或「稍後再說」）——標記這個使用者已經看過，
    /// `refreshForEnteringApp` 之後不會再自動顯示。
    func dismissPreprompt(userID: UUID) {
        showsPreprompt = false
        PushPrepromptDisplayRecord.markShown(userID: userID)
    }

    /// 前置頁 CTA「開啟通知」／設定頁列 `.notDetermined` 態走的「第 1 項流程」共用——跳系統
    /// 對話框，允許就呼叫 `registerForRemoteNotifications()`（票文範圍 2）。
    @discardableResult
    func requestAuthorizationAndRegister() async -> Bool {
        do {
            let granted = try await authorizationService.requestAuthorization()
            authorizationStatus = granted ? .authorized : .denied
            if granted {
                await authorizationService.registerForRemoteNotifications()
            }
            return granted
        } catch {
            // 註冊失敗記 log 不擋 UI（票文範圍 2）。
            didFailToRegister(error: error)
            return false
        }
    }

    /// `AppDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` 轉呼叫
    /// ——hex 化 token 後交給 `submitTokenIfNeeded` 判斷要不要送。
    func didRegister(deviceToken: Data, userID: UUID) async {
        await submitTokenIfNeeded(Self.hexString(from: deviceToken), userID: userID)
    }

    /// `AppDelegate.application(_:didFailToRegisterForRemoteNotificationsWithError:)` 轉呼叫
    /// ——票文範圍 2「註冊失敗記 log 不擋 UI」，不改變任何 store 狀態。
    ///
    /// merge-review R3-m1：`error.localizedDescription` 對沒有 conform `LocalizedError` 的
    /// `AppError`（`AppError.swift:22`）只會印出 Foundation 橋接的泛用文案「無法完成作業。
    /// （LittleSprout.AppError錯誤0 。）」——reviewer 實測三種完全不同根因（`.rejected`／
    /// `.validationRetryable`／`.network`）印出來一模一樣，`AppError.map`（`AppError.swift:246-305`）
    /// 明確保留下來供 log／除錯用的 `message`／`code` 兩欄全部被丟掉，Release log 沒有任何可
    /// 分流的資訊。改印 `String(describing: error)`：`AppError` 是 enum，會印成
    /// `rejected(message: "…", code: Optional("42501"))`，`message`／`code` 都保留；不是
    /// `AppError` 的其他 `Error`（理論上不會發生，`PushAuthorizationService`／
    /// `PushDeviceTokenAPIClient` 的實作皆映射成 `AppError`）一樣印得出型別與內容。裝置 token
    /// 不在 `AppError` 的任何欄位裡，不會外洩。抽成 `static` helper 讓單元測試能直接斷言字串
    /// 內容（`os.Logger` 本身的輸出不是 XCTest 能攔截斷言的東西）。
    func didFailToRegister(error: Error) {
        Self.logger.error(
            "LS-217 push registerForRemoteNotifications 失敗：\(Self.logDescription(for: error), privacy: .public)"
        )
    }

    static func logDescription(for error: Error) -> String {
        String(describing: error)
    }

    /// 去重核心：同一個 (userID, tokenHex) 只送一次 `register_device_token`；RPC 失敗時不標記
    /// 已送出，讓下一次觸發（下次前景／下次登入）自然重試——同時滿足「註冊失敗記 log 不擋 UI」
    /// 與「不會因為一次失敗就永久放棄」兩個要求。不是 `private`：單元測試需要直接呼叫，跳過
    /// `didRegister` 內部才需要的 `Task` 包裝（見該方法）。
    func submitTokenIfNeeded(_ tokenHex: String, userID: UUID) async {
        guard PushDeviceTokenSubmissionRecord.lastSubmittedTokenHex(userID: userID) != tokenHex else { return }
        let key = Self.submissionKey(userID: userID, tokenHex: tokenHex)
        guard !inFlightSubmissions.contains(key) else { return }
        inFlightSubmissions.insert(key)
        defer { inFlightSubmissions.remove(key) }
        do {
            try await deviceTokenAPIClient.registerDeviceToken(token: tokenHex, platform: "ios")
            PushDeviceTokenSubmissionRecord.markSubmitted(tokenHex, userID: userID)
        } catch {
            didFailToRegister(error: error)
        }
    }

    private static func submissionKey(userID: UUID, tokenHex: String) -> String {
        "\(userID.uuidString)|\(tokenHex)"
    }

    static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG
    /// `TapTargetGateHarness`／`#Preview` 用：同步灌狀態，不經過 async 查詢——同
    /// `EULAStore.seedForPreview` 的既有理由（見該檔）。整支 `#if DEBUG` 圍住，Release build
    /// 不會編到。
    func seedForPreview(authorizationStatus: UNAuthorizationStatus) {
        self.authorizationStatus = authorizationStatus
    }
    #endif
}

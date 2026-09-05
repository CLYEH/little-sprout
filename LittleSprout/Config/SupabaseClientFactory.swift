import Foundation
import Supabase

/// 產生 app 執行期用的唯一 `SupabaseClient`。
///
/// 刻意不做成單例常數（`let shared = ...`）：`AuthService`／`FamilyAPIClient` 的具體實作
/// 都是以建構子注入 `SupabaseClient`，測試端可以另外組一個指向 mock `URLSession` 的
/// client（見 LittleSproutTests/Support/TestSupabaseClient.swift）。這裡只負責
/// production 那顆真正打 `AppConfig` 指定專案的 client。
enum SupabaseClientFactory {
    /// 離線開 app 時：SDK 預設（false）會先嘗試用網路刷新本機 session，刷新失敗（連不上網）
    /// 就把 `.initialSession` 事件的 session 灌成 nil——即使 Keychain 裡其實還有一份（可能
    /// 過期的）session，`SupabaseAuthService` 的背景監聽（見該檔 `observeAuthChangesTask`）
    /// 會照單全收，把快取覆寫成 nil，離線回訪被誤判成未登入（LS-55 N1）。設成 true 後 SDK
    /// 改成同步直接發本機儲存的 session（不管有沒有過期），刷新失敗只會維持原值，不會覆寫成
    /// nil；SDK 本身也已警告舊行為（false）將在下個 major 版本移除。
    ///
    /// 抽成常數（而不是直接寫死在 `makeClient()` 裡）並讓
    /// `LittleSproutTests/Support/TestSupabaseClient.swift` 透過 `@testable import` 共用同一個
    /// 值：N1 的測試要釘住的是「正式 factory 真的有開這個旗標」，如果測試端自己另外寫一份
    /// `true`，正式路徑被改掉（或漏改）測試也不會紅，等於沒測到（PR #77 R1 M1）。
    static let emitLocalSessionAsInitialSession = true

    static func makeClient() -> SupabaseClient {
        let url = qaOverride?.url ?? AppConfig.supabaseURL
        // 只在 Debug/Test build 生效（Release build 中 assert 會被編譯器移除）：忘記建立
        // Config/Secrets.xcconfig 時，Base.xcconfig 的安全佔位值仍能讓 app 編譯、啟動，但打
        // 出去的每個請求都注定失敗，而且失敗訊息離「忘記設定本機 xcconfig」很遠、不好查。
        // 這裡在還來得及的時候（app 剛啟動）就地炸掉（LS-49 PR #63 review F7）。
        //
        // 跳過 XCTest 行程：CI／`xcodebuild test` 本來就沒有（也不該有）Config/Secrets.xcconfig
        // ——那是本機開發者才會建立的 gitignored 檔案，測試刻意用 Base.xcconfig 的佔位值跑。
        // `SupabaseClientFactoryTests.test_makeClient_doesNotThrow`（review F11）就是故意在
        // 這個狀態下呼叫 makeClient()：不排除 XCTest 行程的話，這個 assert 在 CI 上 100% 會炸
        // （PR #63 review 第 2 輪實測：本機因為已經有 Secrets.xcconfig 而沒踩到，CI 才踩到）。
        assert(
            isRunningUnderXCTest || isRunningUnderTapTargetGate || url.host != "placeholder.supabase.co",
            "Config/Secrets.xcconfig 未設定（目前用的是 Config/Base.xcconfig 的安全佔位值）——" +
            "本機開發請複製 Config/Secrets.xcconfig.example 為 Config/Secrets.xcconfig 並填入真實值。"
        )
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: qaOverride?.anonKey ?? AppConfig.supabaseAnonKey,
            options: SupabaseClientOptions(
                auth: .init(emitLocalSessionAsInitialSession: emitLocalSessionAsInitialSession)
            )
        )
    }

    /// LS-158：QA 端到端情境測試（`LittleSproutUITests/QA/QASmokeTests`）把 app 指向本機 Supabase
    /// 容器的唯一接線點——`scripts/ops/qa-e2e.sh` 從 `supabase status` 讀 API URL／anon key，經
    /// `TEST_RUNNER_` 環境變數交給 UI test runner，再由 `XCUIApplication.launchEnvironment` 注入
    /// 被測 app（同 `LS_TAP_TARGET_GATE_SCREEN` 的通道）。只在 DEBUG 生效：Release 這個屬性恆為
    /// nil，正式版讀不到、也改不了後端位址。兩個值必須同時存在且合法才覆寫——只給一半＝設定錯，
    /// 照 `AppConfig` 走、讓上面的 assert 或後端錯誤大聲失敗，不做半套。
    private static var qaOverride: (url: URL, anonKey: String)? {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let rawURL = env["LS_QA_API_URL"], let url = URL(string: rawURL), url.host != nil,
              let anonKey = env["LS_QA_ANON_KEY"], !anonKey.isEmpty else { return nil }
        return (url, anonKey)
        #else
        return nil
        #endif
    }

    /// Xcode／`xcodebuild test` 執行 XCTest bundle 時一律會設這個環境變數——業界慣用的偵測法，
    /// 正式發佈的 app（TestFlight／App Store）絕對不會有它。
    ///
    /// 只涵蓋 unit test（`LittleSproutTests`）：那種測試把 XCTest 注入「同一個」app 行程
    /// （`TEST_HOST`），這個環境變數才會出現在這裡讀到的 `ProcessInfo` 裡。
    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// LS-95：≥44pt 點擊目標機械 gate 用 XCUITest 把 app 當「獨立行程」啟動（`TEST_TARGET_NAME`
    /// 機制——實際執行 XCTestCase 的是另一個 XCTRunner 行程，app-under-test 是重新啟動的一份
    /// 全新行程），上面 `isRunningUnderXCTest` 讀的 `XCTestConfigurationFilePath` 因此偵測
    /// 不到（實測：不加這條，`LittleSproutUITests` 啟動 app 當場在這個 assert 炸掉——
    /// `TapTargetGateHarness` 顯示的畫面本身不打真網路，不需要真的 Supabase 專案）。
    /// 直接認 `TapTargetGateHarness` 用的同一把環境變數鍵值，不透過 `#if DEBUG` 限定的
    /// `TapTargetGateHarness` 型別本身（這支檔案沒有 `#if DEBUG`，`assert` 本身已經是
    /// Release build 會被編譯器整段移除的機制，不需要疊第二層條件編譯）。
    private static var isRunningUnderTapTargetGate: Bool {
        ProcessInfo.processInfo.environment["LS_TAP_TARGET_GATE_SCREEN"] != nil
    }
}

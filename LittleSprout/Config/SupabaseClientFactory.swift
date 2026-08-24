import Foundation
import Supabase

/// 產生 app 執行期用的唯一 `SupabaseClient`。
///
/// 刻意不做成單例常數（`let shared = ...`）：`AuthService`／`FamilyAPIClient` 的具體實作
/// 都是以建構子注入 `SupabaseClient`，測試端可以另外組一個指向 mock `URLSession` 的
/// client（見 LittleSproutTests/Support/TestSupabaseClient.swift）。這裡只負責
/// production 那顆真正打 `AppConfig` 指定專案的 client。
enum SupabaseClientFactory {
    static func makeClient() -> SupabaseClient {
        let url = AppConfig.supabaseURL
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
            isRunningUnderXCTest || url.host != "placeholder.supabase.co",
            "Config/Secrets.xcconfig 未設定（目前用的是 Config/Base.xcconfig 的安全佔位值）——" +
            "本機開發請複製 Config/Secrets.xcconfig.example 為 Config/Secrets.xcconfig 並填入真實值。"
        )
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: AppConfig.supabaseAnonKey
        )
    }

    /// Xcode／`xcodebuild test` 執行 XCTest bundle 時一律會設這個環境變數——業界慣用的偵測法，
    /// 正式發佈的 app（TestFlight／App Store）絕對不會有它。
    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

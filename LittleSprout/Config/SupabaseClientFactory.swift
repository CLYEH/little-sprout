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
        // 只在 Debug/Test build 生效：忘記建立 Config/Secrets.xcconfig 時，Base.xcconfig 的
        // 安全佔位值仍能讓 app 編譯、啟動，但打出去的每個請求都注定失敗，而且失敗訊息離
        // 「忘記設定本機 xcconfig」很遠、不好查。這裡在還來得及的時候（app 剛啟動）就地炸掉，
        // Release build 不受影響（assert 在 Release 會被編譯器移除，見 LS-49 PR #63 review F7）。
        assert(
            url.host != "placeholder.supabase.co",
            "Config/Secrets.xcconfig 未設定（目前用的是 Config/Base.xcconfig 的安全佔位值）——" +
            "本機開發請複製 Config/Secrets.xcconfig.example 為 Config/Secrets.xcconfig 並填入真實值。"
        )
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: AppConfig.supabaseAnonKey
        )
    }
}

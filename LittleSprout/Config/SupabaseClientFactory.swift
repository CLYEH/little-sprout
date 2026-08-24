import Supabase

/// 產生 app 執行期用的唯一 `SupabaseClient`。
///
/// 刻意不做成單例常數（`let shared = ...`）：`AuthService`／`FamilyAPIClient` 的具體實作
/// 都是以建構子注入 `SupabaseClient`，測試端可以另外組一個指向 mock `URLSession` 的
/// client（見 LittleSproutTests/Support/SupabaseClientTestSupport.swift）。這裡只負責
/// production 那顆真正打 `AppConfig` 指定專案的 client。
enum SupabaseClientFactory {
    static func makeClient() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: AppConfig.supabaseURL,
            supabaseKey: AppConfig.supabaseAnonKey
        )
    }
}

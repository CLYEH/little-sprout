import Foundation
import Supabase

/// 建一個所有網路請求都走 `MockURLProtocol` 的 `SupabaseClient`，供測試組裝
/// `SupabaseAuthService`／`SupabaseFamilyAPIClient` 使用。`autoRefreshToken: false`：
/// 避免背景刷新計時器在測試執行期間對還沒設定 handler 的請求送出多餘呼叫。
enum TestSupabaseClient {
    static func make(handler: @escaping MockURLProtocol.Handler) -> SupabaseClient {
        MockURLProtocol.setHandler(handler)
        return SupabaseClient(
            supabaseURL: URL(string: "https://test.supabase.co")!,
            supabaseKey: "test-anon-key",
            options: SupabaseClientOptions(
                auth: .init(storage: InMemoryAuthLocalStorage(), autoRefreshToken: false),
                global: .init(session: MockURLProtocol.makeSession())
            )
        )
    }
}

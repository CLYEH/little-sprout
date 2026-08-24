import Auth
import Foundation
@testable import LittleSprout
import Supabase

/// 建一個所有網路請求都走 `MockURLProtocol` 的 `SupabaseClient`，供測試組裝
/// `SupabaseAuthService`／`SupabaseFamilyAPIClient` 使用。`autoRefreshToken: false`：
/// 避免背景刷新計時器在測試執行期間對還沒設定 handler 的請求送出多餘呼叫。
/// `emitLocalSessionAsInitialSession` 直接讀 `SupabaseClientFactory.
/// emitLocalSessionAsInitialSession`（`@testable import`），不在這裡自己另外寫一份 `true`
/// （LS-55 N1／PR #77 R1 M1）——測試端跟正式路徑各自寫值的話，正式 factory 被改掉（或漏改）
/// 測試也不會紅，等於沒測到真正的行為；共用同一個常數才能讓 N1 測試釘住「正式設定真的有
/// 開這個旗標」。
enum TestSupabaseClient {
    /// - Parameter storage: 預設每次呼叫都給一份全新的記憶體儲存（測試互不汙染）。
    ///   LS-55 N1 的離線測試需要讓兩個先後建立的 `SupabaseClient`（模擬「重開 app」）共用
    ///   同一份本機儲存，才能讓第二個 client 讀到第一個 client 存下的 session，這裡才需要
    ///   讓呼叫端自己傳一份共用的 storage 進來。
    static func make(
        storage: AuthLocalStorage = InMemoryAuthLocalStorage(),
        handler: @escaping MockURLProtocol.Handler
    ) -> SupabaseClient {
        MockURLProtocol.setHandler(handler)
        return SupabaseClient(
            supabaseURL: URL(string: "https://test.supabase.co")!,
            supabaseKey: "test-anon-key",
            options: SupabaseClientOptions(
                auth: .init(
                    storage: storage,
                    autoRefreshToken: false,
                    emitLocalSessionAsInitialSession: SupabaseClientFactory.emitLocalSessionAsInitialSession
                ),
                global: .init(session: MockURLProtocol.makeSession())
            )
        )
    }
}

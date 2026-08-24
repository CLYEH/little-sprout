import Foundation

/// 讀取建置期灌進 Info.plist 的 Supabase 環境設定（見 `Config/Base.xcconfig`、
/// `LittleSprout/Info.plist` 的 `SupabaseURL` / `SupabaseAnonKey` 兩個 `$(VAR)` 取代 key，
/// project.yml 用 `INFOPLIST_FILE` 指向那個實體檔——`GENERATE_INFOPLIST_FILE` 的
/// `INFOPLIST_KEY_<Key>` 機制只認 Apple 已知的 key，自訂 key 會被靜默忽略，這裡改回
/// 傳統的實體 Info.plist 機制才保證生效，細節見 project.yml 內的 LS-49 註記）。
///
/// Fail loud：這兩個值若缺失或格式不對，代表 xcconfig／Info.plist 沒接好，
/// 是設定錯誤而非可恢復的執行期狀態，因此用 `precondition` 讓 app 直接停在啟動點，
/// 而不是讓 SupabaseClient 用一個空字串默默建出來、之後在第一次網路呼叫才爆出難懂的錯誤。
enum AppConfig {
    /// Supabase 專案的 REST/Auth/Storage 基底 URL。
    static var supabaseURL: URL {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              !raw.isEmpty,
              let url = URL(string: raw) else {
            preconditionFailure(
                "Info.plist 缺少合法的 SupabaseURL——確認 Config/Base.xcconfig 或 " +
                "Config/Secrets.xcconfig 的 SUPABASE_URL 有值，且 LittleSprout/Info.plist 的 " +
                "SupabaseURL 有正確引用它（$(SUPABASE_URL)）。"
            )
        }
        return url
    }

    /// Supabase 的 publishable（anon）key。這把 key 設計上就是公開的（RLS 才是實際的存取控制邊界），
    /// 不是要保護的機密——但仍走 xcconfig 而非硬寫在原始碼，方便切換 local/cloud 專案。
    static var supabaseAnonKey: String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
              !raw.isEmpty else {
            preconditionFailure(
                "Info.plist 缺少 SupabaseAnonKey——確認 Config/Base.xcconfig 或 " +
                "Config/Secrets.xcconfig 的 SUPABASE_ANON_KEY 有值。"
            )
        }
        return raw
    }
}

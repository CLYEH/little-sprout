import Foundation

/// 讀取建置期灌進 Info.plist 的 Supabase 環境設定（見 `Config/Base.xcconfig`、
/// `project.yml` 的 `INFOPLIST_KEY_SupabaseURL` / `INFOPLIST_KEY_SupabaseAnonKey`）。
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
                "Config/Secrets.xcconfig 的 SUPABASE_URL 有值，且 project.yml 的 " +
                "INFOPLIST_KEY_SupabaseURL 有正確引用它。"
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

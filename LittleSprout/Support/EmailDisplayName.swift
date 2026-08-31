import Foundation

/// 從 Email 地址推導一個可以當「顯示名稱」用的字串——取 `@` 之前的本地部分，去除頭尾空白，
/// 上限 50 字（對齊 `profiles.display_name` 的 `CHECK char_length(btrim(...)) between 1 and 50`，
/// 見 `supabase/migrations/20260822120000_init_schema.sql`）。
///
/// 沒有 email、或本地部分整段是空白時回傳 nil——呼叫端自行決定 fallback 文案（LS-107：
/// `SupabaseFamilyAPIClient.ensureProfileExists` 用它推導 `profiles.display_name` 預設值、
/// `ForkView` 用它推導三岔路問候語裡的名字，兩處的 fallback 文案不一樣，不適合在這裡寫死）。
enum EmailDisplayName {
    static func derive(fromEmail email: String?) -> String? {
        guard let email, let atIndex = email.firstIndex(of: "@") else { return nil }
        let local = String(email[..<atIndex]).trimmingCharacters(in: .whitespaces)
        guard !local.isEmpty else { return nil }
        return String(local.prefix(50))
    }
}

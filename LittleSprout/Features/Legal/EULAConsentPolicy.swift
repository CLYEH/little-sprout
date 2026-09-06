import Foundation

/// LS-190（依 LS-152 稿 `z042Yg`／`rh2Q1`）：EULA 同意頁的出現條件——純函式，跟 View／
/// 網路層完全分離，方便單元測試四種狀態（無紀錄／舊版／同版／新版）。
///
/// `eula_version`（`app_settings.eula_version`）是不透明的版本標籤（目前格式類似
/// 「2026-09-05-draft」，見 `docs/API.md` §11），不保證可排序比大小——`accept_eula(p_version)`
/// 本身也只用逐字相等比對（`is distinct from`，見該 RPC），這裡比照同一種語意：只要使用者
/// 已同意的版本與目前生效版本「不相等」，就必須（重新）出示同意頁，不嘗試判斷孰新孰舊。
enum EULAConsentPolicy {
    /// - Parameters:
    ///   - acceptedVersion: `profiles.eula_accepted_version`——`nil` 代表從未同意過（無紀錄）。
    ///   - currentVersion: `app_settings.eula_version`，呼叫端應先讀這個值（見
    ///     `EULAAPIClient.fetchCurrentVersion()`）。
    /// - Returns: `true`＝必須顯示同意頁；`false`＝已同意目前版本，可直接放行。
    static func shouldPresent(acceptedVersion: String?, currentVersion: String) -> Bool {
        acceptedVersion != currentVersion
    }
}

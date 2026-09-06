import Foundation

/// LS-217：前置說明頁「登入後首次進時間軸顯示一次」的本機旗標——同 `PendingAccountDeletion`
/// 既有的「以 `userID` 分 key 存 `UserDefaults`」手法（見該檔文件註解：同一台裝置換帳號登入時，
/// 不能讓上一位使用者「已經看過」的旗標誤放行成這一位也看過）。
enum PushPrepromptDisplayRecord {
    private static let keyPrefix = "LS217.pushPrepromptShown."

    static func hasShown(userID: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: keyPrefix + userID.uuidString)
    }

    static func markShown(userID: UUID) {
        UserDefaults.standard.set(true, forKey: keyPrefix + userID.uuidString)
    }

    #if DEBUG
    /// 只給測試用——重置某個 `userID` 的旗標，讓多個測試方法之間不互相汙染同一份
    /// `UserDefaults.standard`（同機執行的所有測試共用同一份磁碟儲存）。
    static func reset(userID: UUID) {
        UserDefaults.standard.removeObject(forKey: keyPrefix + userID.uuidString)
    }
    #endif
}

/// LS-217：`register_device_token` 去重——同一個 (userID, tokenHex) 組合只送一次，換帳號或
/// 裝置 token 真的變動時才重送。以 `userID` 分 key（不是單純存最後一次送出的 token）表示換帳號
/// 後這裡讀到的一定是 `nil`，天然會重送——呼應 `docs/API.md` §4 `register_device_token` 的
/// 說明：「同一支裝置換帳號登入時」該重新關聯到新帳號，不能因為裝置 token 沒變就跳過。
enum PushDeviceTokenSubmissionRecord {
    private static let keyPrefix = "LS217.pushDeviceTokenHex."

    static func lastSubmittedTokenHex(userID: UUID) -> String? {
        UserDefaults.standard.string(forKey: keyPrefix + userID.uuidString)
    }

    static func markSubmitted(_ tokenHex: String, userID: UUID) {
        UserDefaults.standard.set(tokenHex, forKey: keyPrefix + userID.uuidString)
    }

    #if DEBUG
    static func reset(userID: UUID) {
        UserDefaults.standard.removeObject(forKey: keyPrefix + userID.uuidString)
    }
    #endif
}

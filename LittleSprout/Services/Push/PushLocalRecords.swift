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
/// 裝置 token 真的變動時才重送。
///
/// merge-review R2 M2：這裡**不能**以 `userID` 分 key 各存各的「上次送過的 token」——APNs
/// device token 是 per-app-install、不隨帳號變動，`device_tokens` 那一列同一時間只可能綁在
/// 一個使用者身上，所以「這支裝置上次送過什麼」的語意必須是**裝置層級單一紀錄**（目前綁定
/// 給誰＋哪個 token），不是「這個使用者上次送過什麼」。R1／R2 版的以 `userID` 分 key 在
/// A→B→**A 再登入**時會出洞：A 自己在第一次登入時留下的紀錄還在，回鍋登入時讀到的不是
/// `nil`、是舊值，去重 guard 會誤判成「已經送過」而不重送，`device_tokens` 因此永遠留在 B
/// 身上（A 的裝置持續收到 B 家庭的推播）。「換帳號後這裡讀到的一定是 `nil`」只在「這支裝置
/// 第一次遇到這個帳號」成立，不是通例。
enum PushDeviceTokenSubmissionRecord {
    private static let bindingKey = "LS217.pushDeviceTokenBinding"

    /// 只有「目前裝置綁定紀錄剛好是這個 (userID, tokenHex) 組合」時才回傳 tokenHex；
    /// 綁定屬於別的使用者（或還沒有任何紀錄）一律視為「沒送過」，讓呼叫端重送。
    static func lastSubmittedTokenHex(userID: UUID) -> String? {
        guard let binding = currentBinding(), binding.userID == userID else { return nil }
        return binding.tokenHex
    }

    static func markSubmitted(_ tokenHex: String, userID: UUID) {
        UserDefaults.standard.set("\(userID.uuidString)|\(tokenHex)", forKey: bindingKey)
    }

    #if DEBUG
    /// 只給測試用——裝置層級單一紀錄，清掉這支裝置目前的整筆綁定；`userID` 參數保留只是
    /// 為了呼叫端維持既有的「每個使用者收尾自己清一次」寫法，實際上清的是同一把 key。
    static func reset(userID: UUID) {
        UserDefaults.standard.removeObject(forKey: bindingKey)
    }
    #endif

    private static func currentBinding() -> (userID: UUID, tokenHex: String)? {
        guard let raw = UserDefaults.standard.string(forKey: bindingKey) else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let userID = UUID(uuidString: parts[0]) else { return nil }
        return (userID: userID, tokenHex: parts[1])
    }
}

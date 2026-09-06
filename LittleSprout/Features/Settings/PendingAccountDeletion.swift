import Foundation

/// LS-193 merge-review R1 M3：`delete_my_account()` RPC 成功、`finalizeAccountDeletion()`
/// （Edge Function `delete-account`）失敗（或 app 在兩者之間被系統回收／使用者強制關閉）時
/// 的本機續傳旗標。`DeleteAccountFlowModel.deletionRequested` 只活在那個 model 實例裡
/// （畫面消失就丟棄，見該屬性文件註解）——不夠：使用者可能在 RPC 成功、EF 還沒打完之前就
/// 把 app 殺掉，下次啟動時需要一個活過 app 生命週期的訊號，讓 `AuthenticatedGate` 知道
/// 「這個使用者的帳號其實已經在半刪除狀態，該直接續傳而不是進正常已登入畫面」。
///
/// **只存布林、以 `userID` 分 key**（不是單一全域旗標）：同一台裝置理論上不會有兩個帳號
/// 同時處於這個狀態，但用 `userID` 分 key 比較不會在「使用者其實還沒真的按過刪除、只是
/// `UserDefaults` 殘留上一位使用者的旗標」這種邊界情況下誤觸發。
///
/// **merge-review R2 i2 訂正**：`clear(userID:)` 只在 EF 真的成功那一刻呼叫（見
/// `PendingAccountDeletionResumer.resumeIfPending(userID:)`）——**登出不清**（`ForkView
/// .signOutTapped`／`SettingsView.signOut`／`DeleteAccountFlowModel.finishAndReturnToWelcome`
/// 都不會呼叫這支）：這個旗標跟帳號本身綁定，不是跟本機 session 綁定；使用者登出後換另一個
/// 帳號登入、或同一個帳號在另一台裝置登入，都應該仍然看得到「這個帳號還在半刪除狀態」並自動
/// 續傳，不能因為中途登出一次就忘記。舊版註解宣稱「登出時都會呼叫」跟實作不符，這裡訂正為
/// 實際行為。
///
/// **用 `UserDefaults` 而非 Keychain**：這個旗標本身不是敏感資訊（不含任何帳號內容，只是
/// 「這個 userID 曾經按過刪除」的布林值），跟隨 app 解除安裝一起消失是可接受的行為
/// （解除安裝等於本機這份續傳線索本來就該歸零，伺服器端 `deletion_requested_at` 才是真正的
/// 事實來源——見 `FamilyStore.accountDeletionInProgressError` 文件註解的「另一台裝置／重灌」
/// 情境）。
enum PendingAccountDeletion {
    private static let keyPrefix = "LS193.pendingAccountDeletion."

    static func isPending(userID: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: keyPrefix + userID.uuidString)
    }

    static func markPending(userID: UUID) {
        UserDefaults.standard.set(true, forKey: keyPrefix + userID.uuidString)
    }

    static func clear(userID: UUID) {
        UserDefaults.standard.removeObject(forKey: keyPrefix + userID.uuidString)
    }
}

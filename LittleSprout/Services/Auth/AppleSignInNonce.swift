import CryptoKit
import Foundation
import Security

/// Sign in with Apple 的 nonce 工具。
///
/// 這裡只做純運算，不碰 `ASAuthorizationAppleIDProvider`——那需要 Sign in with Apple
/// entitlement（待 LS-8），加了在 provisioning 未就緒前會讓本機 build 失敗（見 LS-49 ticket
/// 說明），所以本票只做介面與這段可獨立測試的雜湊/亂數邏輯。
///
/// 呼叫端流程（LS-8 完成、真的接上 `ASAuthorizationAppleIDProvider` 之後）：
///   1. `let raw = AppleSignInNonce.randomNonce()`
///   2. `request.nonce = AppleSignInNonce.sha256(raw)`（餵給 `ASAuthorizationAppleIDRequest`）
///   3. 拿到 credential 後，把「未雜湊」的 raw 傳給 `AuthService.signInWithApple(idToken:nonce:)`
///      ——Supabase 驗證的是 ID token 裡的 nonce claim 對不對得上這個原始值的雜湊，
///      所以傳的必須是 raw，不是已經雜湊過的那份。
enum AppleSignInNonce {
    /// 與 Apple 官方範例一致的字元集（含官方範例本身就漏掉的 'W'，這是已知且無害的巧合，
    /// 不是本檔的錯字——熵來自 charset 大小與長度，少一個字元不影響安全性）。
    private static let charset: [Character] = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._"
    )

    /// 產生一段密碼學安全的隨機字串。
    static func randomNonce(length: Int = 32) -> String {
        precondition(length > 0)
        var result = ""
        var remaining = length

        while remaining > 0 {
            var randomBytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
            precondition(
                status == errSecSuccess,
                "SecRandomCopyBytes 失敗（狀態碼 \(status)）——沒有安全的亂數來源就不該產生 nonce"
            )

            for byte in randomBytes where remaining > 0 {
                // 拒絕取樣：byte 超過字元集大小的部分丟棄，避免 mod 造成的分布偏差。
                if byte < charset.count {
                    result.append(charset[Int(byte)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    /// SHA256 雜湊，輸出小寫十六進位字串——`ASAuthorizationAppleIDRequest.nonce` 要的格式。
    static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.map { String(format: "%02x", $0) }.joined()
    }
}

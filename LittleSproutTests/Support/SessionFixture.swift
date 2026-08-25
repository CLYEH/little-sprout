import Foundation

/// 產生一份符合 Supabase Auth `/token`／`/verify` 回應契約的 session JSON，供
/// `SupabaseAuthServiceTests`／`SupabaseFamilyAPIClientTests` 共用（後者需要先讓
/// client 處於「已登入」狀態才能測 `createFamily` 這類要求 `auth.uid()` 的呼叫）。
enum SessionFixture {
    /// - Parameter expiresAt: session 的到期時間，預設一小時後（未過期）。LS-55 N1 的離線測試
    ///   需要組一份「已過期」的 session（例如傳 `Date().addingTimeInterval(-3600)`）來模擬
    ///   「先前登入過、重開 app 時本機還留著一份過期 session」的情境。
    static func json(userID: UUID, email: String, expiresAt: Date = Date().addingTimeInterval(3600)) -> Data {
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
          "access_token": "fake-access-token",
          "token_type": "bearer",
          "expires_in": 3600,
          "expires_at": \(expiresAt.timeIntervalSince1970),
          "refresh_token": "fake-refresh-token",
          "user": {
            "id": "\(userID.uuidString)",
            "aud": "authenticated",
            "role": "authenticated",
            "email": "\(email)",
            "app_metadata": {},
            "user_metadata": {},
            "identities": [],
            "created_at": "\(now)",
            "updated_at": "\(now)",
            "is_anonymous": false
          }
        }
        """
        return Data(json.utf8)
    }
}

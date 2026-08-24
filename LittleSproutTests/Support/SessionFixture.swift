import Foundation

/// 產生一份符合 Supabase Auth `/token`／`/verify` 回應契約的 session JSON，供
/// `SupabaseAuthServiceTests`／`SupabaseFamilyAPIClientTests` 共用（後者需要先讓
/// client 處於「已登入」狀態才能測 `createFamily` 這類要求 `auth.uid()` 的呼叫）。
enum SessionFixture {
    static func json(userID: UUID, email: String) -> Data {
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
          "access_token": "fake-access-token",
          "token_type": "bearer",
          "expires_in": 3600,
          "expires_at": \(Date().addingTimeInterval(3600).timeIntervalSince1970),
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

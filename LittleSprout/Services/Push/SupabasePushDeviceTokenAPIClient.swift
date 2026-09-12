import Foundation
import Supabase

/// `PushDeviceTokenAPIClient` 的 Supabase 實作。方法 ↔ RPC 對照見協定檔的文件註解。
final class SupabasePushDeviceTokenAPIClient: PushDeviceTokenAPIClient {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func registerDeviceToken(token: String, platform: String) async throws {
        do {
            try await client.rpc(
                "register_device_token", params: ["p_token": token, "p_platform": platform]
            ).execute()
        } catch {
            throw AppError.map(error)
        }
    }
}

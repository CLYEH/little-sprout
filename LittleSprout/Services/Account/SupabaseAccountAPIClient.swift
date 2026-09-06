import Foundation
import Supabase

/// `AccountAPIClient` 的 Supabase 實作。方法 ↔ RPC／端點對照見協定檔的文件註解。
final class SupabaseAccountAPIClient: AccountAPIClient {
    let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    /// `LS050` 專屬處理：PostgREST 把 RPC 的 `RAISE EXCEPTION ... DETAIL` 原樣放進
    /// `PostgrestError.detail`（JSON 字串），這裡解碼成 `[FamilyPendingTransfer]`；解不出來
    /// （contract 走鐘）一律 fail loud（`.server`），不要默默回空清單讓 04b 顯示一個沒有任何
    /// 待轉移家庭、卻又進不去的畫面。
    func deleteMyAccount() async throws -> DeleteMyAccountOutcome {
        do {
            try await client.rpc("delete_my_account").execute()
            return .success
        } catch let error as PostgrestError
            where error.code == LSErrorCode.ownerMustTransferBeforeAccountDeletion.rawValue {
            return .mustTransferOwnership(families: try Self.parsePendingTransfers(error))
        } catch {
            throw AppError.map(error)
        }
    }

    private static func parsePendingTransfers(_ rpcError: PostgrestError) throws -> [FamilyPendingTransfer] {
        guard let detail = rpcError.detail, let data = detail.data(using: .utf8) else {
            throw AppError.server(message: "LS050 缺少待轉移家庭清單（detail 為空）", code: rpcError.code)
        }
        do {
            return try JSONDecoder().decode([FamilyPendingTransfer].self, from: data)
        } catch let decodingError {
            throw AppError.server(message: "無法解析待轉移家庭清單：\(decodingError)", code: rpcError.code)
        }
    }

    /// `401`＝呼叫者在 GoTrue 端已經不存在（見 docs/API.md §10「冪等語意」）——視為已達成目的，
    /// 不當成失敗往外拋；其餘非 2xx 一律映射成 `AppError` 往外拋。
    func finalizeAccountDeletion() async throws {
        do {
            try await client.functions.invoke("delete-account")
        } catch FunctionsError.httpError(let code, _) where code == 401 {
            return
        } catch {
            throw AppError.map(error)
        }
    }
}

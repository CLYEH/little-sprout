import Foundation
import Supabase

/// LS-348：登入落點第一批 REST 請求（`app_settings`／`profiles`／`families`，`AuthenticatedGate`
/// 登入後併發送出）遇到 PostgREST `PGRST303`（`JWT issued at future`）時，以同一個呼叫重送一次。
///
/// 實測（LS-348 kong／PostgREST 對照）：帶**剛簽發**使用者 JWT 的第一批請求，偶發有最早抵達的
/// 一兩支被 PostgREST 以 `iat` 超前判退，同一秒稍後抵達、帶同一把 token 的請求卻是 200——伺服器
/// 端判定的暫態，重送即過；不是 client 端 token 尚未套用（那會是 `42501`）。只重送一次：若伺服器
/// 時鐘真的持續偏差，第二次的錯誤照實往上拋（`AppError.map` 歸 `.retryableSystem`），不無限重試；
/// 其他錯誤（含真正的權限不足 `42501`）一律不重送。
func retryingOnceOnTransientJWTRejection<T>(_ operation: () async throws -> T) async throws -> T {
    do {
        return try await operation()
    } catch let error as PostgrestError where error.code == "PGRST303" {
        return try await operation()
    }
}

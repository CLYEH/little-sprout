import Foundation

/// EULA 同意（LS-197 後端）的型別化 client 介面。
///
/// 方法 ↔ RPC／資料表對照（供 `docs/API.md` §4／§11 對帳）：
///   - `fetchCurrentVersion`  → SELECT `public.app_settings.eula_version`（欄位級 SELECT，
///                              **不得**帶 `where id = true`，見 `docs/API.md` §4 `accept_eula`）
///   - `fetchAcceptedVersion` → SELECT `public.profiles.eula_accepted_version`（表級 SELECT，
///                              `id = auth.uid()` 一定可見，見 `private.peer_profile_ids()`）
///   - `acceptEULA`           → RPC `accept_eula(p_version text)`
///
/// 錯誤一律映射為 `AppError`，不直接往外拋 PostgREST 的 error 型別。
protocol EULAAPIClient: Sendable {
    /// 目前生效的條款版本；`accept_eula()` 要送的 `p_version` 就是這個值。
    func fetchCurrentVersion() async throws -> String

    /// 呼叫者自己最近一次同意的版本；`nil`＝從未同意過。
    func fetchAcceptedVersion(userID: UUID) async throws -> String?

    /// 寫入同意紀錄。`version` 必須等於呼叫當下的 `fetchCurrentVersion()`，否則拿到 `LS055`
    /// （見 `docs/API.md` §5）。
    func acceptEULA(version: String) async throws
}

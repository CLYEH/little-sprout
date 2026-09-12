import Foundation

/// 推播裝置 token 註冊（LS-58 後端）的型別化 client 介面——同 `SafetyAPIClient`／`EULAAPIClient`
/// 既有分層慣例。
///
/// 方法 ↔ RPC 對照（供 `docs/API.md` §4 對帳）：
///   - `registerDeviceToken` → RPC `register_device_token(p_token text, p_platform text)`
///
/// **只有這兩個參數**——`docs/API.md` §3 `device_tokens` 表只有 `token`／`user_id`／
/// `platform`／`updated_at` 四欄，沒有 sandbox/production 環境或 app 版本欄位；`p_platform`
/// 目前只接受 `"ios"`（RPC 端 cast 失敗會回 `22P02`，見 API.md §4）。
///
/// 錯誤一律映射為 `AppError`，不直接往外拋 PostgREST 的 error 型別。
protocol PushDeviceTokenAPIClient: Sendable {
    func registerDeviceToken(token: String, platform: String) async throws
}

import Foundation

/// App 層的登入狀態快照。刻意不直接暴露 Supabase 的 `Session`/`User`——`AuthService` 是
/// app 對外的認證邊界，呼叫端不該耦合到特定後端 SDK 的型別（也讓測試端能組出這個值
/// 而不需要真的建一個 Supabase `Session`）。
struct AuthSession: Equatable, Sendable {
    let userID: UUID
    let email: String?
    let expiresAt: Date
}

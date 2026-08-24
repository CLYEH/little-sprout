import Auth
import Foundation

/// 測試用的記憶體版 session 儲存，取代正式環境的 Keychain（`KeychainLocalStorage`）——
/// 讓 `SupabaseAuthService` 測試不依賴模擬器 Keychain 狀態，且每個測試都是乾淨的空白起點。
final class InMemoryAuthLocalStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func remove(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}

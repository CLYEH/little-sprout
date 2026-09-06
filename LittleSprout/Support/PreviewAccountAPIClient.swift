#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview`／`TapTargetGateHarness` 用的假 `AccountAPIClient`——不打真網路，
/// 同 `PreviewFamilyAPIClient` 的角色。預設兩支呼叫都直接成功，需要非預設樣本（例如 LS050
/// 需先轉移、失敗態）的呼叫端改用 `LittleSproutTests/Support/StubAccountAPIClient.swift`
/// （XCTest 專用，見該檔）或在 `#Preview`／harness 端另建一個帶自訂閉包的最小實作。
final class PreviewAccountAPIClient: AccountAPIClient, @unchecked Sendable {
    func deleteMyAccount() async throws -> DeleteMyAccountOutcome { .success }
    func finalizeAccountDeletion() async throws {}
}
#endif

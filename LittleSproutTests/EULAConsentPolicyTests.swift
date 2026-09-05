@testable import LittleSprout
import XCTest

/// LS-190 票文驗收「版本判定寫成純函式並單元測試（無紀錄／舊版／同版／新版四案）」。
final class EULAConsentPolicyTests: XCTestCase {
    func test_noRecord_mustPresent() {
        XCTAssertTrue(EULAConsentPolicy.shouldPresent(acceptedVersion: nil, currentVersion: "2026-09-05-draft"))
    }

    func test_olderAcceptedVersion_mustPresent() {
        XCTAssertTrue(EULAConsentPolicy.shouldPresent(
            acceptedVersion: "2026-08-01-draft", currentVersion: "2026-09-05-draft"
        ))
    }

    func test_sameAcceptedVersion_doesNotPresent() {
        XCTAssertFalse(EULAConsentPolicy.shouldPresent(
            acceptedVersion: "2026-09-05-draft", currentVersion: "2026-09-05-draft"
        ))
    }

    /// 「新版」案——`eula_version` 是不透明字串，不保證可排序：即使已同意的版本字面上
    /// 「大於」目前版本，兩者不相等一樣要求重新同意（同 `accept_eula()` 逐字比對的語意，
    /// 見 `EULAConsentPolicy` 文件註解），不嘗試判斷孰新孰舊。
    func test_differentVersionEitherDirection_mustPresent() {
        XCTAssertTrue(EULAConsentPolicy.shouldPresent(
            acceptedVersion: "2026-12-01-draft", currentVersion: "2026-09-05-draft"
        ))
    }
}

import XCTest
@testable import LittleSprout
import UserNotifications

/// LS-217 票文驗收：「首次顯示旗標邏輯」——純函式，同 `EULAConsentPolicyTests` 既有慣例。
final class PushPrepromptPolicyTests: XCTestCase {
    func testNotDetermined_neverShownBefore_shouldPresent() {
        XCTAssertTrue(
            PushPrepromptPolicy.shouldPresent(authorizationStatus: .notDetermined, hasShownBefore: false)
        )
    }

    func testNotDetermined_shownBefore_shouldNotPresent() {
        XCTAssertFalse(
            PushPrepromptPolicy.shouldPresent(authorizationStatus: .notDetermined, hasShownBefore: true)
        )
    }

    /// 票文範圍 1：「`UNAuthorizationStatus` 非 `.notDetermined` 時永不顯示」——這個條件優先於
    /// 「首次」，即使 `hasShownBefore` 是 false（例如：使用者從系統設定手動開了權限，但本機
    /// 旗標從未被寫過）也不該再自動彈出前置頁。
    func testAuthorized_neverShownBefore_shouldNotPresent() {
        XCTAssertFalse(
            PushPrepromptPolicy.shouldPresent(authorizationStatus: .authorized, hasShownBefore: false)
        )
    }

    func testDenied_neverShownBefore_shouldNotPresent() {
        XCTAssertFalse(
            PushPrepromptPolicy.shouldPresent(authorizationStatus: .denied, hasShownBefore: false)
        )
    }
}

import XCTest
@testable import LittleSprout

/// LS-188：`get_family_quota` RPC 回傳列的純算術——`usedFraction`（Print Roll 填格比例）與
/// `isFull`（09b 已滿判定，LS002 觸發的同一條件）。鎖住的意圖：這兩個值決定使用者在儲存空間
/// 頁看到的是「還有空間」還是「已滿」文案與版面，算錯會讓使用者誤以為還能上傳（或反過來）。
final class FamilyQuotaTests: XCTestCase {
    func testUsedFraction_partial() {
        let quota = FamilyQuota(usedBytes: 2_254_857_830, quotaBytes: 5_368_709_120)
        XCTAssertEqual(quota.usedFraction, 0.42, accuracy: 0.001)
    }

    func testUsedFraction_full_isOne() {
        let quota = FamilyQuota(usedBytes: 5_368_709_120, quotaBytes: 5_368_709_120)
        XCTAssertEqual(quota.usedFraction, 1.0, accuracy: 0.0001)
    }

    func testUsedFraction_clampsAboveOne() {
        // 理論上不會發生（DB 有硬防線擋超額寫入），但呼叫端不該顯示超過 100% 的用量條。
        let quota = FamilyQuota(usedBytes: 6_000_000_000, quotaBytes: 5_368_709_120)
        XCTAssertEqual(quota.usedFraction, 1.0, accuracy: 0.0001)
    }

    func testUsedFraction_zeroQuota_treatedAsFullNotDivideByZero() {
        let quota = FamilyQuota(usedBytes: 0, quotaBytes: 0)
        XCTAssertEqual(quota.usedFraction, 1.0, accuracy: 0.0001)
    }

    func testIsFull_exactlyAtLimit() {
        let quota = FamilyQuota(usedBytes: 5_368_709_120, quotaBytes: 5_368_709_120)
        XCTAssertTrue(quota.isFull)
    }

    func testIsFull_belowLimit() {
        let quota = FamilyQuota(usedBytes: 2_254_857_830, quotaBytes: 5_368_709_120)
        XCTAssertFalse(quota.isFull)
    }
}

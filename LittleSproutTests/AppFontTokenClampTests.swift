@testable import LittleSprout
import XCTest

/// R1 F5：`.code`（07 邀請碼展示）在 AX3 走 `.largeTitle` 曲線會長到 ~92pt，但
/// `design/littlesprout.pen` variables 明確給了兩檔——default 60／AX3 72，不是照系統曲線
/// 外插。`@ScaledMetric` 只在 View body 內才會依 Dynamic Type 環境算出實際值，沒辦法在
/// XCTest 裡直接組一個環境去驗證縮放後的字級；這裡改為驗證 `ScaledFontModifier` 實際套用的
/// 那個純函式（`AppFontToken.clampedSize`），涵蓋 F5 具體失敗情境釘的兩個檔位（60 → 92）。
final class AppFontTokenClampTests: XCTestCase {
    func test_code_hasSeventyTwoPointUpperBound() {
        XCTAssertEqual(AppFontToken.code.maxScaledSize, 72)
    }

    func test_clampedSize_belowMax_returnsUnchanged() {
        // Large（一般字級）下 `.code` 自然值就是 60pt，不該被夾住。
        XCTAssertEqual(AppFontToken.clampedSize(60, maxScaledSize: AppFontToken.code.maxScaledSize), 60)
    }

    func test_clampedSize_atAX3NaturalValue_clampsToDesignMax() {
        // AX3 下 `.largeTitle` 曲線把 60pt 基準長到 ~92pt（60 × 1.53）——這是 F5 抓到的具體
        // 失敗情境本身：不夾住的話邀請碼六碼＋tracking(4) 在 iPhone 上會被截斷。
        XCTAssertEqual(AppFontToken.clampedSize(92, maxScaledSize: AppFontToken.code.maxScaledSize), 72)
    }

    func test_clampedSize_noMax_returnsUnchanged() {
        // 其餘 token（例如 `.otp`）沒有設上限，沿用系統 Dynamic Type 曲線。
        XCTAssertNil(AppFontToken.otp.maxScaledSize)
        XCTAssertEqual(AppFontToken.clampedSize(999, maxScaledSize: AppFontToken.otp.maxScaledSize), 999)
    }
}

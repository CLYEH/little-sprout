import XCTest

/// LS-95：≥44pt 點擊目標機械 gate 的正式檢查——這是 `tap-target-check.sh` 真正倚賴的兩個
/// test method（`-only-testing:LittleSproutUITests` 會連 `TapTargetGateSelfTests` 一起跑，
/// 但只有這個檔案量測的是真正的產品畫面）。
///
/// 新增受測畫面：`TapTargetGateScreenName` 加一個 case、`TapTargetGateHarness.hostView(for:)`
/// 補對應分支，這裡再加一個 `test<畫面名>` 方法。
@MainActor
final class TapTargetGateTests: XCTestCase {
    func testOTPVerificationView() {
        assertAllTappablesMeetMinimum(.otpVerification)
    }

    func testSettingsView() {
        assertAllTappablesMeetMinimum(.settings)
    }

    /// 任一元件 <44pt 就用 `XCTFail` 記一筆——逐一累計，不是遇到第一個違規就提前結束，讓
    /// `tap-target-check.sh` 能一次點名所有違規者（LS-17 QA1 就是同一畫面上不只一顆違規）。
    private func assertAllTappablesMeetMinimum(_ screen: TapTargetGateScreenName) {
        let app = TapTargetMeasurement.launch(screen)
        for message in TapTargetMeasurement.violations(in: app) {
            XCTFail(message)
        }
    }
}

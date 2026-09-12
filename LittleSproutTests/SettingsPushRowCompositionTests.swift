import XCTest
@testable import LittleSprout
import UserNotifications

/// LS-217 票文驗收：「狀態→列 value 對應」——純函式，同 `SettingsContentSafetyCompositionTests`
/// 既有慣例，不需要真的建立 View。
final class SettingsPushRowCompositionTests: XCTestCase {
    func testNotDetermined_isOffAndValueIsOff() {
        XCTAssertFalse(SettingsPushRowComposition.isOn(for: .notDetermined))
        XCTAssertEqual(SettingsPushRowComposition.valueText(for: .notDetermined), "關閉")
    }

    func testDenied_isOffAndValueIsOff() {
        XCTAssertFalse(SettingsPushRowComposition.isOn(for: .denied))
        XCTAssertEqual(SettingsPushRowComposition.valueText(for: .denied), "關閉")
    }

    func testAuthorized_isOnAndValueIsOn() {
        XCTAssertTrue(SettingsPushRowComposition.isOn(for: .authorized))
        XCTAssertEqual(SettingsPushRowComposition.valueText(for: .authorized), "開啟")
    }

    func testProvisional_isOnAndValueIsOn() {
        XCTAssertTrue(SettingsPushRowComposition.isOn(for: .provisional))
        XCTAssertEqual(SettingsPushRowComposition.valueText(for: .provisional), "開啟")
    }

    func testEphemeral_isOnAndValueIsOn() {
        XCTAssertTrue(SettingsPushRowComposition.isOn(for: .ephemeral))
        XCTAssertEqual(SettingsPushRowComposition.valueText(for: .ephemeral), "開啟")
    }
}

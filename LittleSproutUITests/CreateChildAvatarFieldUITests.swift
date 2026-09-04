import XCTest

/// LS-169：建檔頁（08）頭像欄從「相機圖示、刻意不掛任何互動」（LS-113 範圍說明）改成真的
/// 可點的 `PhotosPicker` 觸發鈕——這支測試釘住「可點」這件事本身，不是尺寸（尺寸由
/// `TapTargetGateTests.testCreateChildView` 的標準 44pt 掃描涵蓋）。
///
/// 刻意不真的 `tap()` 觸發系統相簿選圖：`PhotosPicker` 開啟的是另一個行程的系統 UI（跨行程
/// sheet、可能觸發相簿權限對話框），驅動它需要照片庫權限與模擬器相簿種子資料，屬於 Apple
/// 系統 UI 而不是本票程式碼——同 `tap-target-exemptions.txt` 對 `WelcomeView` 的既有理由
/// （SignInWithApple 官方元件「系統渲染、量測意義有限」）。這裡只驗證「這個元件存在、
/// accessibility label 正確、且真的可以被命中（`isHittable`）」——這正是「可點」在 UI 測試
/// 層級可靠驗證的邊界。
@MainActor
final class CreateChildAvatarFieldUITests: XCTestCase {
    func test_avatarField_existsAndIsHittable() {
        let app = TapTargetMeasurement.launch(.createChild)
        TapTargetMeasurement.assertScreenRendered(.createChild, in: app)

        let avatarField = app.buttons["新增寶貝照片，目前尚未選擇"]

        XCTAssertTrue(avatarField.waitForExistence(timeout: 10), "頭像欄應該是一個可點的按鈕")
        XCTAssertTrue(avatarField.isHittable, "頭像欄的點擊區域應該是可命中的，不是視覺佔位")
    }
}

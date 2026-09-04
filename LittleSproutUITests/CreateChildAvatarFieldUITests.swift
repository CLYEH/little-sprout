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
    /// LS-174：`waitForExistence` 只保證元素進了 accessibility tree，不保證它「當下這一刻」
    /// 已經 `isHittable`——CI runner 偶爾在兩者之間還有一次佈局／動畫尚未穩定，同一個 SHA
    /// 在 LS-158 PR #281 attempt 1 紅、rerun 綠（純 runner 時序，不是程式碼問題）。改成對
    /// `isHittable` 本身掛 `expectation(for:evaluatedWith:)` 輪詢等待，並額外釘住 frame 高度
    /// ≥44pt（`TapTargetMeasurement.minSide`，與 `TapTargetGateTests` 同一把尺）——後者是
    /// 佈局穩定後就不會抖動的幾何量測，用來在 `isHittable` 這個較脆的訊號之外多一道不受
    /// runner 時序影響的證據。
    func test_avatarField_existsAndIsHittable() {
        let app = TapTargetMeasurement.launch(.createChild)
        TapTargetMeasurement.assertScreenRendered(.createChild, in: app)

        let avatarField = app.buttons["新增寶貝照片，目前尚未選擇"]
        XCTAssertTrue(avatarField.waitForExistence(timeout: 10), "頭像欄應該是一個可點的按鈕")

        let isHittablePredicate = NSPredicate(format: "isHittable == true")
        let hittableExpectation = expectation(for: isHittablePredicate, evaluatedWith: avatarField)
        wait(for: [hittableExpectation], timeout: 5)

        let frame = avatarField.frame
        XCTAssertGreaterThanOrEqual(
            frame.height, TapTargetMeasurement.minSide,
            "頭像欄的點擊區域高度應該 ≥\(Int(TapTargetMeasurement.minSide))pt，不是視覺佔位"
        )
    }
}

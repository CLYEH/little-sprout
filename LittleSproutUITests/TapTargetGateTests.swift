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

    /// merge-review R1 M5：改註冊進 harness，取代原本 `tap-target-exemptions.txt` 的具名排除。
    func testDiaryEditorView() {
        assertAllTappablesMeetMinimum(.diaryEditor)
    }

    /// LS-169：頭像欄從視覺佔位改成真的可點的 `PhotosPicker` 觸發鈕——改註冊進 harness，
    /// 取代原本 `tap-target-exemptions.txt` 的具名排除（同 `testDiaryEditorView` 的理由）。
    func testCreateChildView() {
        assertAllTappablesMeetMinimum(.createChild)
    }

    /// LS-126 delta 復審 m2：`TimelineView` 整體仍在 `tap-target-exemptions.txt`（其餘元件
    /// 需要 seed 資料），這裡只蓋 Header 建立鈕（`.preview()` 空狀態即可渲染）。
    func testTimelineViewDefaultState() {
        assertAllTappablesMeetMinimum(.timelineDefaultState)
    }

    /// LS-136：`SectionTabBar`（`cmp/Tab Bar` 全字級純 icon）四顆 cell 的預設態點擊區。
    func testSectionTabView() {
        assertAllTappablesMeetMinimum(.sectionTabView)
    }

    /// LS-165：`AlbumsView` 從 `ContentUnavailableView` 佔位換成正式內容——這裡只蓋 Header
    /// 「新增相簿」建立鈕（`.preview()` 空狀態即可渲染，同 `testTimelineViewDefaultState`
    /// 的既有理由）。
    func testAlbumsViewDefaultState() {
        assertAllTappablesMeetMinimum(.albumsDefaultState)
    }

    /// LS-165：`AlbumSummaryCardView` 的排除理由宣稱「導覽由外層 AlbumsView 的
    /// NavigationLink 負責，該處已走 tap-target-check 涵蓋的互動路徑」——這支測試讓那句話
    /// 成立：量測有相簿列表時每張卡片（`NavigationLink`）的點擊區。
    func testAlbumsViewPopulatedState() {
        assertAllTappablesMeetMinimum(.albumsPopulatedState)
    }

    /// LS-165：「新增相簿」sheet，初始態（姓名欄／寶貝標記欄／建立鈕）不需要任何 seed 資料。
    func testCreateAlbumView() {
        assertAllTappablesMeetMinimum(.createAlbum)
    }

    /// 任一元件 <44pt 就用 `XCTFail` 記一筆——逐一累計，不是遇到第一個違規就提前結束，讓
    /// `tap-target-check.sh` 能一次點名所有違規者（LS-17 QA1 就是同一畫面上不只一顆違規）。
    /// merge-review R1 B1：先斷言畫面真的渲染出來，harness 靜默失效不會被誤判成「這個畫面
    /// 沒有違規」。
    private func assertAllTappablesMeetMinimum(_ screen: TapTargetGateScreenName) {
        let app = TapTargetMeasurement.launch(screen)
        TapTargetMeasurement.assertScreenRendered(screen, in: app)
        for message in TapTargetMeasurement.violations(in: app) {
            XCTFail(message)
        }
    }
}

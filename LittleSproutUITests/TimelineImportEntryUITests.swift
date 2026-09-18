import XCTest

/// LS-315 票文驗收：「`timeline.importPhotos` 可及」＋「空狀態文案存在」。`.timelineDefaultState`
/// harness host（`.preview()` 三個 store 皆空狀態）同時滿足兩個情境——Header 兩顆鈕與空狀態
/// `ContentUnavailableView` 都不需要 seed 資料就會渲染（見 `TapTargetGateHarness.swift`
/// `timelineDefaultStateHost` 文件註解）。
///
/// 「點擊進 PHPicker」不在這裡自動化——系統 `PHPickerViewController`／相片庫授權對話框不是
/// 可穩定機械驗證的對象，同 `AlbumDetailViewTests`／`AlbumDetailAX3UITests` 既有慣例（那兩支
/// 也只驗「加入照片」鈕存在，不驗點擊後的系統 UI），改由模擬器互動（mobile-mcp）驗證，見
/// PR body／handoff。
@MainActor
final class TimelineImportEntryUITests: XCTestCase {
    func testImportButton_existsAndIsAccessible() {
        let app = TapTargetMeasurement.launch(.timelineDefaultState)
        TapTargetMeasurement.assertScreenRendered(.timelineDefaultState, in: app)

        let importButton = app.buttons[QAAccessibilityID.timelineImportPhotos]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "Header「匯入」鈕應該可及（identifier 找到）")
        XCTAssertTrue(importButton.isHittable, "「匯入」鈕應該可觸達")
        XCTAssertEqual(importButton.label, "匯入", "可見文字應該是「匯入」（Notes `orXbN`：Label in Name）")
    }

    func testEmptyState_showsImportGuidanceCopy() {
        let app = TapTargetMeasurement.launch(.timelineDefaultState)
        TapTargetMeasurement.assertScreenRendered(.timelineDefaultState, in: app)

        let guidance = app.staticTexts["點上方的「匯入」把手機裡的舊照片搬進來，或點「新增回憶」寫下第一篇日記。"]
        XCTAssertTrue(
            guidance.waitForExistence(timeout: 10),
            "空狀態文案應該依 Notes `F77gCE` 逐字抄值，「匯入」領頭（C1c：不加按鈕）"
        )
    }
}

@testable import LittleSprout
import XCTest

/// merge-review R1 M1／I4：先前只驗到 `AppError` 內容（`message.contains("50MB")`），但那個
/// 欄位是 log 用的，從沒出現在螢幕上——`error.userFacingMessage` 忽略 associated value，
/// `.validationRetryable` 一律回通用句，50 MiB 超限與空內文兩段文案因此永遠不會被使用者看到。
/// 這裡直接測「畫面上真的會顯示的字」，釘住 M1 修復的意圖，不是只測 AppError 分類本身。
final class DiaryPublishErrorMessageTests: XCTestCase {
    func test_payloadTooLarge_showsFileSizeSpecificMessage() {
        let error = AppError.validationRetryable(
            message: "log only, not shown", code: DiaryMediaErrorCode.payloadTooLarge
        )

        let text = DiaryPublishErrorMessage.displayText(for: error)

        XCTAssertTrue(text.contains("50MB"), "使用者要看得懂是檔案太大，不是通用句「請確認內容後再試一次」")
    }

    func test_otherValidationRetryable_fallsBackToGenericUserFacingMessage() {
        let error = AppError.validationRetryable(message: "23514", code: "23514")

        let text = DiaryPublishErrorMessage.displayText(for: error)

        XCTAssertEqual(text, error.userFacingMessage, "非 413 的驗證錯誤沒有專屬文案，維持既有通用句")
        XCTAssertFalse(text.contains("50MB"), "不該把其他驗證錯誤誤判成超限文案")
    }

    func test_networkError_fallsBackToGenericUserFacingMessage() {
        let error = AppError.network(message: "offline")

        let text = DiaryPublishErrorMessage.displayText(for: error)

        XCTAssertEqual(text, error.userFacingMessage)
    }
}

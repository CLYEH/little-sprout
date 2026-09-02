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

    /// QA 視覺對稿 FAIL（LS-125 comment `ed017e85`）：`.network`（`URLError` 連線失敗／逾時
    /// 經 `AppError.map` 映射出來的結果）先前落到通用 fallback，顯示 `AppError.network` 自己
    /// 的句子而不是 `peiRC` 稿面逐字文案——這裡改回稿面文案，不再是「網路連線有問題，請檢查
    /// 網路連線後再試一次。」那句更通用的版本。
    func test_networkError_showsScreenSpecificRetryMessage() {
        let error = AppError.network(message: "offline")

        let text = DiaryPublishErrorMessage.displayText(for: error)

        XCTAssertEqual(text, "發佈失敗，請檢查網路連線後再試一次。")
    }

    /// 跟上一條互補：`.server`（後端 5xx／看不懂的回應）刻意不受這次修法影響，繼續走
    /// `AppError.server` 的通用句——這是「兩條映射」的第二條，兩者文案不同、不能共用同一句，
    /// mutation 若把 `.network` 分支誤刪或誤把這條也導去 `.network` 的文案，這條測試會紅。
    func test_serverError_fallsBackToGenericUserFacingMessage() {
        let error = AppError.server(message: "internal error", code: nil)

        let text = DiaryPublishErrorMessage.displayText(for: error)

        XCTAssertEqual(text, error.userFacingMessage)
        XCTAssertNotEqual(text, "發佈失敗，請檢查網路連線後再試一次。", "伺服器錯誤不該顯示網路文案")
    }
}

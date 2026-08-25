@testable import LittleSprout
import XCTest

/// 02 畫面客戶端格式檢查——只攔截「明顯還沒打完」的輸入（02b 錯誤畫面的觸發條件），
/// 不是完整的 RFC 5322 驗證（後端仍是最終權威）。
final class EmailFormatTests: XCTestCase {
    func test_validEmail_isValid() {
        XCTAssertTrue(EmailFormat.isValid("grandma@example.com"))
        XCTAssertTrue(EmailFormat.isValid("parent.name@sub.example.co"))
    }

    func test_missingTLD_isInvalid() {
        // 設計稿 02b 的示範案例：「grandma@example」少了頂級網域。
        XCTAssertFalse(EmailFormat.isValid("grandma@example"))
    }

    func test_missingAtSign_isInvalid() {
        XCTAssertFalse(EmailFormat.isValid("grandmaexample.com"))
    }

    func test_emptyLocalPart_isInvalid() {
        XCTAssertFalse(EmailFormat.isValid("@example.com"))
    }

    func test_emptyDomainLabel_isInvalid() {
        XCTAssertFalse(EmailFormat.isValid("grandma@.com"))
        XCTAssertFalse(EmailFormat.isValid("grandma@example."))
    }

    func test_singleCharacterTLD_isInvalid() {
        XCTAssertFalse(EmailFormat.isValid("grandma@example.c"))
    }

    func test_multipleAtSigns_isInvalid() {
        XCTAssertFalse(EmailFormat.isValid("grandma@@example.com"))
    }

    func test_emptyString_isInvalid() {
        XCTAssertFalse(EmailFormat.isValid(""))
    }
}

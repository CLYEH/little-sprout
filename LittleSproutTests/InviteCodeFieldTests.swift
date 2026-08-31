@testable import LittleSprout
import XCTest

/// `InviteCodeField.normalize`：06 系列輸入框的大寫／去空白/截斷規則（票文 Scope 第 1 點）。
final class InviteCodeFieldTests: XCTestCase {
    func test_normalize_lowercase_becomesUppercase() {
        XCTAssertEqual(InviteCodeField.normalize("k7m2fd"), "K7M2FD")
    }

    func test_normalize_stripsNonAlphanumeric() {
        XCTAssertEqual(InviteCodeField.normalize("k7m-2fd"), "K7M2FD")
    }

    func test_normalize_truncatesToCellCount() {
        XCTAssertEqual(InviteCodeField.normalize("K7M2FD8888"), "K7M2FD")
    }

    func test_normalize_empty_returnsEmpty() {
        XCTAssertEqual(InviteCodeField.normalize(""), "")
    }
}

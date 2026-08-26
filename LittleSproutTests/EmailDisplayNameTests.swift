@testable import LittleSprout
import XCTest

final class EmailDisplayNameTests: XCTestCase {
    func test_derive_normalEmail_returnsLocalPart() {
        XCTAssertEqual(EmailDisplayName.derive(fromEmail: "grandma@example.com"), "grandma")
    }

    func test_derive_nilEmail_returnsNil() {
        XCTAssertNil(EmailDisplayName.derive(fromEmail: nil))
    }

    func test_derive_noAtSign_returnsNil() {
        XCTAssertNil(EmailDisplayName.derive(fromEmail: "not-an-email"))
    }

    func test_derive_whitespaceOnlyLocalPart_returnsNil() {
        XCTAssertNil(EmailDisplayName.derive(fromEmail: "  @example.com"))
    }

    func test_derive_longLocalPart_truncatesTo50Characters() {
        let longLocal = String(repeating: "a", count: 80)
        let result = EmailDisplayName.derive(fromEmail: "\(longLocal)@example.com")
        XCTAssertEqual(result?.count, 50)
    }
}

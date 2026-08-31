@testable import LittleSprout
import XCTest

final class ChildAvatarInitialTests: XCTestCase {
    func test_initial_chineseName_usesLastCharacter() {
        XCTAssertEqual(ChildAvatarInitial.initial(for: "陳小安"), "安")
        XCTAssertEqual(ChildAvatarInitial.initial(for: "陳小軒"), "軒")
    }

    func test_initial_latinName_usesUppercasedFirstLetter() {
        XCTAssertEqual(ChildAvatarInitial.initial(for: "Emma Chen"), "E")
        XCTAssertEqual(ChildAvatarInitial.initial(for: "emma"), "E")
    }

    func test_initial_trimsWhitespace() {
        XCTAssertEqual(ChildAvatarInitial.initial(for: "  陳小安  "), "安")
    }

    func test_initial_emptyString_returnsEmpty() {
        XCTAssertEqual(ChildAvatarInitial.initial(for: "   "), "")
    }
}

import Foundation
@testable import LittleSprout
import XCTest

/// 06／06b／06c「改用貼上邀請連結」與 deep link（`littlesprout://invite/<code>`，LS-39 已註冊
/// scheme；`https://sproutday.app/invite/<code>`，LS-436）共用的解析邏輯——見 `InviteCodeParser` 文件註解。
final class InviteCodeParserTests: XCTestCase {
    // MARK: - extractCode：完整連結

    func test_extractCode_fullDeepLink_returnsUppercaseCode() {
        XCTAssertEqual(InviteCodeParser.extractCode(from: "littlesprout://invite/k7m2fd"), "K7M2FD")
    }

    func test_extractCode_deepLinkWithTrailingSlash_returnsCode() {
        XCTAssertEqual(InviteCodeParser.extractCode(from: "littlesprout://invite/K7M2FD/"), "K7M2FD")
    }

    func test_extractCode_deepLinkWrongScheme_returnsNil() {
        XCTAssertNil(InviteCodeParser.extractCode(from: "https://invite/K7M2FD"))
    }

    func test_extractCode_deepLinkWrongHost_returnsNil() {
        XCTAssertNil(InviteCodeParser.extractCode(from: "littlesprout://auth/callback"))
    }

    func test_extractCode_deepLinkNoCode_returnsNil() {
        XCTAssertNil(InviteCodeParser.extractCode(from: "littlesprout://invite"))
    }

    // MARK: - extractCode：直接貼上碼本身

    func test_extractCode_bareCode_normalizesCase() {
        XCTAssertEqual(InviteCodeParser.extractCode(from: "k7m2fd"), "K7M2FD")
    }

    func test_extractCode_bareCodeWithDashesAndSpaces_stripsPunctuation() {
        XCTAssertEqual(InviteCodeParser.extractCode(from: " k7m-2fd "), "K7M2FD")
    }

    func test_extractCode_emptyString_returnsNil() {
        XCTAssertNil(InviteCodeParser.extractCode(from: "   "))
    }

    func test_extractCode_onlyPunctuation_returnsNil() {
        XCTAssertNil(InviteCodeParser.extractCode(from: "---"))
    }

    // MARK: - code(fromDeepLink:)：`onOpenURL` 直接拿到的 URL

    func test_codeFromDeepLink_validURL_returnsCode() {
        let url = URL(string: "littlesprout://invite/K7M2FD")!
        XCTAssertEqual(InviteCodeParser.code(fromDeepLink: url), "K7M2FD")
    }

    func test_codeFromDeepLink_oldDomain_returnsNil() {
        let url = URL(string: "https://littlesprout.app/invite/K7M2FD")!
        XCTAssertNil(InviteCodeParser.code(fromDeepLink: url))
    }

    // MARK: - https 分享連結（LS-436）

    func test_codeFromDeepLink_sproutdayHTTPS_returnsCode() {
        let url = URL(string: "https://sproutday.app/invite/k7m2fd")!
        XCTAssertEqual(InviteCodeParser.code(fromDeepLink: url), "K7M2FD")
    }

    func test_extractCode_sproutdayHTTPS_returnsCode() {
        XCTAssertEqual(InviteCodeParser.extractCode(from: "https://sproutday.app/invite/K7M2FD/"), "K7M2FD")
    }

    func test_extractCode_sproutdayHTTPSWrongPathOrOldDomain_returnsNil() {
        XCTAssertNil(InviteCodeParser.extractCode(from: "https://sproutday.app/legal/privacy-policy"))
        XCTAssertNil(InviteCodeParser.extractCode(from: "https://littlesprout.app/invite/K7M2FD"))
    }
}

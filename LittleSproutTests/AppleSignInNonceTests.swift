@testable import LittleSprout
import XCTest

final class AppleSignInNonceTests: XCTestCase {
    func test_randomNonce_hasRequestedLength() {
        XCTAssertEqual(AppleSignInNonce.randomNonce(length: 32).count, 32)
        XCTAssertEqual(AppleSignInNonce.randomNonce(length: 8).count, 8)
    }

    func test_randomNonce_isNotDeterministic() {
        // 兩次呼叫幾乎必然不同（32 字元、charset ≥60，碰撞機率可忽略）；如果測到相同值，
        // 代表亂數來源壞了（例如誤用固定 seed），這條測試就是要在那種情況下 fail loud。
        let first = AppleSignInNonce.randomNonce()
        let second = AppleSignInNonce.randomNonce()
        XCTAssertNotEqual(first, second)
    }

    func test_sha256_isDeterministicForSameInput() {
        let input = "fixed-nonce-value"
        XCTAssertEqual(AppleSignInNonce.sha256(input), AppleSignInNonce.sha256(input))
    }

    func test_sha256_matchesKnownVector() {
        // SHA256("") 是公開已知的固定值——用來確認實作真的是 SHA256，不是隨便湊出來剛好
        // 「看起來像雜湊」的東西。
        XCTAssertEqual(
            AppleSignInNonce.sha256(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func test_sha256_outputIsLowercaseHex() {
        let digest = AppleSignInNonce.sha256("little-sprout")
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}

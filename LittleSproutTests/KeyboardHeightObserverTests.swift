@testable import LittleSprout
import XCTest

/// PR #165 review I2：`KeyboardHeightObserver.height(endFrame:screenBounds:)` 是不碰
/// UIKit 的純函式，直接測三種情境，不需要模擬器。
final class KeyboardHeightObserverTests: XCTestCase {
    func test_dockedKeyboard_returnsOverlapHeight() {
        // 一般鍵盤：下緣貼齊螢幕底，遮住的高度＝鍵盤本身高度。
        let screenBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let endFrame = CGRect(x: 0, y: 844 - 346, width: 390, height: 346)
        XCTAssertEqual(KeyboardHeightObserver.height(endFrame: endFrame, screenBounds: screenBounds), 346)
    }

    func test_floatingKeyboardInMiddle_returnsZero() {
        // iPad 懸浮鍵盤浮在畫面中間，下緣沒有貼齊螢幕底——不算遮住底部 UI。
        let screenBounds = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let endFrame = CGRect(x: 200, y: 500, width: 620, height: 216)
        XCTAssertEqual(KeyboardHeightObserver.height(endFrame: endFrame, screenBounds: screenBounds), 0)
    }

    func test_noKeyboardFrame_returnsZero() {
        // 對應收鍵盤（`keyboardWillHideNotification`）沒有真實 frame 可用的情境。
        let screenBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        XCTAssertEqual(KeyboardHeightObserver.height(endFrame: .zero, screenBounds: screenBounds), 0)
    }
}

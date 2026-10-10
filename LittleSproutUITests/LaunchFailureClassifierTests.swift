import XCTest

/// LS-465：啟動重試只對三種啟動階段訊息成立，斷言失敗訊息不得觸發（否則重試會吞掉真的紅燈）。
final class LaunchFailureClassifierTests: XCTestCase {
    func testClassifierAcceptsOnlyTheThreeLaunchFailureMessages() {
        let launchMessages = [
            "Failed to launch <XCUIApplicationImpl: 0x1> via Xcode: Timed out while launching application via Xcode.",
            "Timed out while launching application",
            "Failed to get launch progress for com.clyeh.sproutday",
            "Failed to launch com.clyeh.sproutday"
        ]
        for message in launchMessages {
            XCTAssertTrue(LaunchFailureClassifier.isLaunchFailure(message), "啟動階段訊息應可重試：\(message)")
        }

        let otherMessages = [
            "XCTAssertTrue failed - Head Title 應顯示日記本文摘要（見 DiaryDeleteConfirmationCopy.excerpt）",
            "XCTAssertTrue failed - AX3 下所有列都應該存在於畫面樹",
            "XCTAssertEqual failed: (\"1\") is not equal to (\"2\")",
            "Failed to get matching snapshot: Timed out while loading accessibility",
            ""
        ]
        for message in otherMessages {
            XCTAssertFalse(LaunchFailureClassifier.isLaunchFailure(message), "斷言／其他失敗不得重試：\(message)")
        }
    }
}

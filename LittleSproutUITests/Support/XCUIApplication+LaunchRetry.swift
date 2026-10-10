import XCTest

/// LS-465（LS-413 池 `e3c7a7ed`／`9461c6b6`／`4c89ef28`）：app 啟動逾時重試。
///
/// 為什麼要重試：ci-ipad／ci-ui 慢 runner 偶發 `XCUIApplication.launch()` 本身逾時（log：`<unknown>:0: error:
/// -[…] : Failed to launch <XCUIApplicationImpl…> via Xcode: Timed out while launching application via Xcode.`，
/// 也見 `Failed to get launch progress`）——不是斷言失敗、也不是等待邏輯問題，重跑一輪要 17–40 分。
/// XCTest 對 launch 逾時是**記錄 XCTIssue 後回傳**（不是丟 ObjC 例外），所以可以用
/// `XCTExpectFailure(options:)` 的 `issueMatcher` 只吞「訊息屬於啟動階段」的那一種 issue、其他 issue 照常紅
/// （`LaunchFailureClassifier` 是唯一判斷處，`LaunchFailureClassifierTests` 釘死三種訊息）。
/// 只重試一次；第二次 `launch()` 不再包 `XCTExpectFailure`，仍失敗就真的紅。
enum LaunchFailureClassifier {
    /// 啟動階段失敗的訊息特徵；斷言失敗（`XCTAssert…`）不含這三者。
    static let launchFailureMarkers = [
        "Timed out while launching", "Failed to get launch progress", "Failed to launch"
    ]

    static func isLaunchFailure(_ message: String) -> Bool {
        launchFailureMarkers.contains { message.contains($0) }
    }
}

/// `XCTExpectedFailure.Options.issueMatcher` 不保證在主執行緒呼叫，用鎖保護旗標。
private final class LaunchFailureObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var matchedValue = false

    var matched: Bool {
        lock.lock()
        defer { lock.unlock() }
        return matchedValue
    }

    func match(_ issue: XCTIssue) -> Bool {
        guard LaunchFailureClassifier.isLaunchFailure(issue.compactDescription) else { return false }
        lock.lock()
        matchedValue = true
        lock.unlock()
        return true
    }
}

extension XCUIApplication {
    /// 取代測試內直接呼叫的 `launch()`：啟動階段逾時時 `terminate()` 後重試一次，其餘行為與 `launch()` 相同。
    func launchWithRetry() {
        let observer = LaunchFailureObserver()
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { observer.match($0) }
        var threw = false
        XCTExpectFailure("LS-465 launch retry：啟動逾時視為可重試", options: options) {
            threw = LSCatchObjCException { launch() }
        }
        guard observer.matched else {
            // 例外被吞掉但 issue 不是啟動階段那三種：不能讓測試靜默通過。
            if threw { XCTFail("LS-465：launch() 丟出例外但不是啟動逾時（已記錄的 issue 才是真因）") }
            return
        }
        print("[launch-retry] 第一次啟動逾時，terminate 後重試一次")
        XCTContext.runActivity(named: "LS-465 launch retry") { _ in
            terminate()
            launch()
        }
    }
}

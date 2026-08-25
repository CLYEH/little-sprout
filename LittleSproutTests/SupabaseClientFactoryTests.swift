@testable import LittleSprout
import XCTest

final class SupabaseClientFactoryTests: XCTestCase {
    /// 純粹的建構煙霧測試：`makeClient()` 不該 crash 或 throw（本機/CI 兩種
    /// Config/Base.xcconfig 狀態都要能組出一個 client，即使指向的是安全佔位值）。
    func test_makeClient_doesNotThrow() {
        XCTAssertNoThrow(SupabaseClientFactory.makeClient())
    }
}

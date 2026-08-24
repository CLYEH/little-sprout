@testable import LittleSprout
import XCTest

/// `AppConfig` 讀的是 xcconfig 灌進 Info.plist 的值，本機（有 Config/Secrets.xcconfig）與 CI
/// （只有 Config/Base.xcconfig 的佔位值）拿到的實際字串不同，所以這裡只驗證「有讀到格式正確
/// 的值」，不斷言特定字面值——這正是這條測試要守住的東西：確認 project.yml 的
/// INFOPLIST_KEY_SupabaseURL / INFOPLIST_KEY_SupabaseAnonKey 真的把 build setting 接進了
/// LittleSprout.app 的 Info.plist，`AppConfig` 也真的讀得到（測試由 LittleSprout.app 當
/// host，見 TEST_HOST／BUNDLE_LOADER，`Bundle.main` 在測試行程裡就是那個 app bundle）。
final class AppConfigTests: XCTestCase {
    func test_supabaseURL_isWellFormedHTTPSURL() {
        let url = AppConfig.supabaseURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertNotNil(url.host)
    }

    func test_supabaseAnonKey_isNonEmpty() {
        XCTAssertFalse(AppConfig.supabaseAnonKey.isEmpty)
    }
}

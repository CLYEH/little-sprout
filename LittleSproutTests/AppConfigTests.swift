@testable import LittleSprout
import XCTest

/// `AppConfig` 讀的是 xcconfig 灌進 Info.plist 的值，本機（有 Config/Secrets.xcconfig）與 CI
/// （只有 Config/Base.xcconfig 的佔位值）拿到的實際字串不同，所以這裡只驗證「有讀到格式正確
/// 的值」，不斷言特定字面值——這正是這條測試要守住的東西：確認 project.yml 的
/// `INFOPLIST_FILE` 真的把 xcconfig 的 build setting 接進了 `LittleSprout/Info.plist` 的
/// `$(SUPABASE_URL)`/`$(SUPABASE_ANON_KEY)` 取代，`AppConfig` 也真的讀得到（測試由
/// LittleSprout.app 當 host，見 TEST_HOST／BUNDLE_LOADER，`Bundle.main` 在測試行程裡就是
/// 那個 app bundle）。
final class AppConfigTests: XCTestCase {
    func test_supabaseURL_isWellFormedURL() {
        let url = AppConfig.supabaseURL
        // http 也接受：Config/Base.xcconfig 自己的文件說本機可以把 SUPABASE_URL 指到
        // `supabase start` 印出的本機 API URL（預設 http://127.0.0.1:54321），不強制 https。
        XCTAssertTrue(["https", "http"].contains(url.scheme ?? ""))
        XCTAssertNotNil(url.host)
    }

    func test_supabaseAnonKey_isNonEmpty() {
        XCTAssertFalse(AppConfig.supabaseAnonKey.isEmpty)
    }
}

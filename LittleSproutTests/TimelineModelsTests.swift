import Foundation
@testable import LittleSprout
import XCTest

/// LS-216 R2（merge-review R1 M3）：`ReactorRow` 的 PostgREST embed 解碼——`reactions` join
/// `profiles` 這條路徑，按讚者若已離開家庭，`profiles_select`（`security invoker`，
/// `peer_profile_ids()` 只認「目前」同家庭的人）會把那一列濾掉，embed 回傳
/// `"profiles": null`（`reactions` 那一列本身還在，只是關聯不到）。這裡直接對 PostgREST 會
/// 吐出的 JSON 形狀跑 `JSONDecoder`，不透過網路層 stub——`ReactorRow.init(from:)` 是純解碼
/// 邏輯，用真實 JSON fixture 驗證比 mock 一層 API client 更直接。
final class TimelineModelsTests: XCTestCase {
    func test_reactorRow_decode_normalProfile_usesDisplayName() throws {
        let json = """
        [{"user_id":"11111111-1111-1111-1111-111111111111","profiles":{"display_name":"陳志明"}}]
        """
        let rows = try JSONDecoder().decode([ReactorRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].displayName, "陳志明")
        XCTAssertEqual(rows[0].userID, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    }

    /// 按讚者已離開家庭：PostgREST embed 回 `"profiles": null`——不得讓整份 `[ReactorRow]`
    /// 解碼失敗，顯示名稱退回「家人」（見 `ReactorRow.init(from:)` 文件註解）。
    func test_reactorRow_decode_nullProfile_fallsBackToGenericName() throws {
        let json = """
        [
          {"user_id":"11111111-1111-1111-1111-111111111111","profiles":{"display_name":"陳志明"}},
          {"user_id":"22222222-2222-2222-2222-222222222222","profiles":null}
        ]
        """
        let rows = try JSONDecoder().decode([ReactorRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 2, "其中一位的 profiles 是 null 不該讓整份解碼失敗")
        XCTAssertEqual(rows[0].displayName, "陳志明")
        XCTAssertEqual(rows[1].displayName, "家人")
        XCTAssertEqual(rows[1].userID, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    }

    /// LS-345 R2（merge-review R1 M1）：`avatar_url` 現在也隨 `profiles` embed 一起解碼——
    /// mutation：把 `ReactorRow.init(from:)` 裡 `avatarURL = try? profile.decode(...)` 改回
    /// 不解碼（恆 nil），這支測試會抓到。
    func test_reactorRow_decode_normalProfile_decodesAvatarURL() throws {
        let json = """
        [{
          "user_id":"11111111-1111-1111-1111-111111111111",
          "profiles":{"display_name":"陳志明","avatar_url":"family-a/avatars/user-a.jpg"}
        }]
        """
        let rows = try JSONDecoder().decode([ReactorRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].avatarURL, "family-a/avatars/user-a.jpg")
    }

    /// `profiles` 是 null（已離開家庭）時 `avatarURL` 同顯示名稱一起退化，不特別遮蔽——沿用
    /// 顯示名稱的既有降級規則（見型別文件註解「LS-345 R2」段）。
    func test_reactorRow_decode_nullProfile_avatarURLIsNil() throws {
        let json = """
        [{"user_id":"22222222-2222-2222-2222-222222222222","profiles":null}]
        """
        let rows = try JSONDecoder().decode([ReactorRow].self, from: Data(json.utf8))
        XCTAssertNil(rows[0].avatarURL)
    }
}

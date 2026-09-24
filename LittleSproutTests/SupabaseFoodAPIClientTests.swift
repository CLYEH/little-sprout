import Foundation
@testable import LittleSprout
import Supabase
import XCTest

/// `SupabaseFoodAPIClient`：`food_catalog` 表查詢形狀與 `list_child_food_records` RPC 的編碼／解碼／錯誤映射
/// （`MockURLProtocol` 攔截，不打真網路，同 `SupabaseChildAPIClientTests` 的模式）。
final class SupabaseFoodAPIClientTests: XCTestCase {
    private let childID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    /// 只讀 `active = true`、依 `sort_order` 升冪——下架品項不能進圖鑑（也就不進計數句分母）。
    func test_listFoodCatalog_queriesActiveRowsOrderedBySortOrder_decodesAllergensAndAge() async throws {
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/food_catalog")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(query.contains(URLQueryItem(name: "active", value: "eq.true")), "\(query)")
            // supabase-swift 會附上預設 `.nullslast`（`sort_order` 是 NOT NULL，不影響結果）。
            let order = query.first { $0.name == "order" }?.value ?? ""
            XCTAssertTrue(order.hasPrefix("sort_order.asc"), "\(query)")
            XCTAssertTrue(query.contains(URLQueryItem(
                name: "select", value: "id,name_zh,category,sort_order,allergens,min_age_months"
            )), "\(query)")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [
              {"id": "milk_pudding", "name_zh": "布丁", "category": "dairy", "sort_order": 231,
               "allergens": ["milk", "egg"], "min_age_months": null},
              {"id": "fresh_milk", "name_zh": "鮮奶", "category": "dairy", "sort_order": 226,
               "allergens": ["milk"], "min_age_months": 12}
            ]
            """.utf8))
        }

        let items = try await SupabaseFoodAPIClient(client: client).listFoodCatalog()

        XCTAssertEqual(items.map(\.id), ["milk_pudding", "fresh_milk"])
        XCTAssertEqual(items[0].category, .dairy)
        XCTAssertEqual(items[0].allergens, ["milk", "egg"], "陣列順序照 DB（「含〇〇等」取第一種）")
        XCTAssertNil(items[0].minAgeMonths)
        XCTAssertEqual(items[1].minAgeMonths, 12)
    }

    /// DB CHECK 把類別釘死在 8 個值；未知值＝大聲失敗（不默默藏起那些食物讓計數對不上）。
    func test_listFoodCatalog_unknownCategory_throws() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"id": "x", "name_zh": "x", "category": "space_food", "sort_order": 1,
              "allergens": [], "min_age_months": null}]
            """.utf8))
        }
        do {
            _ = try await SupabaseFoodAPIClient(client: client).listFoodCatalog()
            XCTFail("未知類別應該解碼失敗")
        } catch {
            XCTAssertTrue(error is AppError, "錯誤要映射成 AppError，實際：\(error)")
        }
    }

    func test_listChildFoodRecords_sendsChildID_decodesPlainDate() async throws {
        let client = TestSupabaseClient.make { [childID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/list_child_food_records")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_child_id"] as? String, childID.uuidString)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "id": "11111111-1111-1111-1111-111111111111",
              "family_id": "33333333-3333-3333-3333-333333333333",
              "child_id": "\(childID.uuidString)",
              "food_id": "pumpkin",
              "author_id": null,
              "first_tried_on": "2025-11-18",
              "media_id": null,
              "note": null,
              "reaction": "liked",
              "created_at": "2025-11-18T03:00:00Z",
              "updated_at": "2025-11-18T03:00:00Z",
              "deleted_at": null,
              "deleted_by": null
            }]
            """.utf8))
        }

        let records = try await SupabaseFoodAPIClient(client: client).listChildFoodRecords(childID: childID)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].foodID, "pumpkin")
        XCTAssertEqual(records[0].reaction, "liked")
        XCTAssertEqual(FoodBookCopy.cellDate(records[0].firstTriedOn), "2025/11/18")
    }

    func test_listChildFoodRecords_permissionDenied_mapsToAppError() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 403, body: Data("""
            {"code": "42501", "message": "permission denied for function list_child_food_records"}
            """.utf8))
        }
        do {
            _ = try await SupabaseFoodAPIClient(client: client).listChildFoodRecords(childID: childID)
            XCTFail("42501 應該拋錯")
        } catch {
            XCTAssertTrue(error is AppError, "錯誤要映射成 AppError，實際：\(error)")
        }
    }
}

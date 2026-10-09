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

    // MARK: - LS-380：寫入與照片來源

    /// 6 個具名參數在 SQL 端都沒有預設值——nil 也要送出明確的 JSON null，否則 PostgREST 找不到函式簽章。
    func test_upsertChildFoodRecord_sendsAllSixKeysWithExplicitNulls() async throws {
        let client = TestSupabaseClient.make { [childID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/upsert_child_food_record")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(
                Set(payload.keys),
                ["p_child_id", "p_food_id", "p_first_tried_on", "p_media_id", "p_note", "p_reaction"]
            )
            XCTAssertEqual(payload["p_child_id"] as? String, childID.uuidString)
            XCTAssertEqual(payload["p_food_id"] as? String, "taro")
            XCTAssertEqual(payload["p_first_tried_on"] as? String, "2026-08-20")
            XCTAssertTrue(payload["p_media_id"] is NSNull)
            XCTAssertTrue(payload["p_note"] is NSNull)
            XCTAssertEqual(payload["p_reaction"] as? String, "disliked")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            {"id": "11111111-1111-1111-1111-111111111111", "family_id": "33333333-3333-3333-3333-333333333333",
             "child_id": "\(childID.uuidString)", "food_id": "taro", "author_id": null,
             "first_tried_on": "2026-08-20", "media_id": null, "note": null, "reaction": "disliked",
             "created_at": "2026-08-20T03:00:00Z", "updated_at": "2026-08-20T03:00:00Z",
             "deleted_at": null, "deleted_by": null}
            """.utf8))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let picked = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 9)))

        let saved = try await SupabaseFoodAPIClient(client: client).upsertChildFoodRecord(FoodRecordUpsert(
            childID: childID, foodID: "taro", firstTriedOn: picked, mediaID: nil, note: nil, reaction: .disliked
        ))

        XCTAssertEqual(saved.foodID, "taro")
        XCTAssertEqual(FoodBookCopy.cellDate(saved.firstTriedOn), "2026/8/20")
    }

    func test_upsertChildFoodRecord_checkViolation_mapsToAppError() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code": "23514", "message": "new row violates check constraint"}
            """.utf8))
        }
        do {
            _ = try await SupabaseFoodAPIClient(client: client).upsertChildFoodRecord(FoodRecordUpsert(
                childID: childID, foodID: "taro", firstTriedOn: Date(), mediaID: nil, note: nil, reaction: nil
            ))
            XCTFail("23514 應該拋錯")
        } catch {
            XCTAssertEqual(
                error as? AppError, .validationRetryable(message: "new row violates check constraint", code: "23514")
            )
        }
    }

    func test_deleteChildFoodRecord_sendsRecordID() async throws {
        let recordID = UUID()
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/delete_child_food_record")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_id"] as? String, recordID.uuidString)
            return MockURLProtocol.StubResponse(statusCode: 204, body: Data())
        }

        try await SupabaseFoodAPIClient(client: client).deleteChildFoodRecord(id: recordID)
    }

    /// 03d（LS-441）：以寶貝 id 呼叫 RPC `list_family_photos_for_food`（家庭解析、排除飲食專屬照片、新到舊都在後端），
    /// `p_limit` 送 `FamilyPhotoQuery.limit`。
    func test_listFamilyPhotos_callsRPCWithChildAndLimit() async throws {
        let client = TestSupabaseClient.make { [childID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/list_family_photos_for_food")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_child_id"] as? String, childID.uuidString)
            XCTAssertEqual(payload["p_limit"] as? Int, FamilyPhotoQuery.limit)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"id": "44444444-4444-4444-4444-444444444444", "storage_path": "f/2026/08/a.jpg",
              "thumb_path": "f/2026/08/a_thumb.jpg", "taken_at": null, "created_at": "2026-08-20T03:00:00Z"}]
            """.utf8))
        }

        let photos = try await SupabaseFoodAPIClient(client: client).listFamilyPhotos(childID: childID)

        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos[0].displayPath, "f/2026/08/a_thumb.jpg")
        XCTAssertNil(photos[0].takenAt)
    }
}

import Foundation
@testable import LittleSprout
import XCTest

/// LS-383：時間軸「第一次吃到〇〇」卡片（`food_first`）的資料層與卡片規則——
/// - 驗收②「feed item 解碼四態」：`food_first` 解成已知 kind；組裝後無照片／有照片／只有日期三態的內容與
///   卡片區塊組合；與同日日記落在同一個 Day Divider（同日並列）。
/// - 驗收②「Book Row 導向該類別」：`TimelineRoute.foodBook(for:)` 帶的是那項食物的類別，不是圖鑑預設第一類。
/// - 驗收②「無互動列」：`food_first` 不能互動、`TimelineStore` 不替它查愛心計數（`get_reaction_counts` 不收
///   `food_first`，送了必撞 enum 轉型錯誤）。
///
/// 示範資料沿 LS-326 Notes `UsJkk`：小安，出生 2025-04-20。
@MainActor
final class FoodFirstTimelineTests: XCTestCase {
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let childID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let child = Child(
        id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, name: "小安",
        birthday: BirthdayFormat.date(fromWireString: "2025-04-20")!, avatarURL: nil, deletedAt: nil, createdAt: Date()
    )
    private let pumpkin = FoodCatalogItem(
        id: "pumpkin", nameZh: "南瓜", category: .grainRoot, sortOrder: 9, allergens: [], minAgeMonths: nil
    )
    private let yogurt = FoodCatalogItem(
        id: "yogurt", nameZh: "優格", category: .dairy, sortOrder: 3, allergens: ["milk"], minAgeMonths: nil
    )

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    // MARK: - 解碼

    /// `get_family_timeline` 回 `kind: "food_first"` → `.foodFirst`（不再落到 LS-329 的 `.unknown` 被濾掉）。
    func test_fetchTimelinePointers_foodFirst_decodesAsKnownKind() async throws {
        let refID = UUID()
        let client = TestSupabaseClient.make { [childID] _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "kind": "food_first",
              "ref_id": "\(refID.uuidString)",
              "occurred_at": "2026-08-20T00:00:00Z",
              "child_ids": ["\(childID.uuidString)"],
              "comment_count": 0
            }]
            """.utf8))
        }
        let pointers = try await SupabaseTimelineAPIClient(client: client).fetchTimelinePointers(
            familyID: familyID, childID: nil, cursor: nil, limit: 20
        )
        XCTAssertEqual(pointers.map(\.kind), [.foodFirst])
        XCTAssertEqual(FeedKind.foodFirst.rawValue, "food_first")
    }

    /// `child_food_records` 直接讀一列（`first_tried_on` 是 Postgres `date` 字串）→ `ChildFoodRecord`，查詢帶 `id=in.(…)`。
    func test_fetchFoodRecords_decodesWireRowAndFiltersByID() async throws {
        let recordID = UUID()
        let client = TestSupabaseClient.make { [familyID, childID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/child_food_records")
            XCTAssertEqual(request.url?.query?.contains(recordID.uuidString), true, "應以 id in 篩選")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "id": "\(recordID.uuidString)", "family_id": "\(familyID.uuidString)",
              "child_id": "\(childID.uuidString)", "food_id": "pumpkin", "author_id": null,
              "first_tried_on": "2025-11-18", "media_id": null, "note": null, "reaction": null,
              "created_at": "2025-11-18T10:00:00Z", "updated_at": "2025-11-18T10:00:00Z"
            }]
            """.utf8))
        }
        let rows = try await SupabaseTimelineAPIClient(client: client).fetchFoodRecords(ids: [recordID])
        XCTAssertEqual(rows.map(\.foodID), ["pumpkin"])
        XCTAssertEqual(rows.first?.firstTriedOn, BirthdayFormat.date(fromWireString: "2025-11-18"))
    }

    // MARK: - 四態

    /// ① 沒有照片：反應＋一句話都有，照片區不畫，也不替它查 media／簽名。
    func test_assemble_noPhoto_contentHasNoPhotoAndSkipsMediaQuery() async throws {
        let record = makeRecord(foodID: "pumpkin", day: "2025-11-18", mediaID: nil, note: "一口接一口，把整碗吃光了。")
        let stub = stubClient(records: [record], items: [pumpkin])

        let content = try await assembleOne(record, stub: stub)

        XCTAssertNil(content.photo)
        XCTAssertEqual(content.item, pumpkin)
        XCTAssertEqual(FoodFirstCardCopy.sections(for: content), [.head, .note, .bookRow, .signature])
        XCTAssertEqual(FoodFirstCardCopy.reaction(record)?.label, "喜歡")
        XCTAssertTrue(stub.fetchMediaCalls.isEmpty, "沒有 media_id 的食物卡不該查 media")
        XCTAssertTrue(stub.signedURLsCalls.isEmpty, "沒有照片就不簽名")
    }

    /// ② 有照片：走時間軸既有的 media 縮圖簽名（`thumb_path` 優先），一批一次。
    func test_assemble_withPhoto_signsThumbnailViaTimelineMediaPath() async throws {
        let mediaID = UUID()
        let record = makeRecord(foodID: "pumpkin", day: "2025-11-18", mediaID: mediaID, note: "吃光了")
        let stub = stubClient(records: [record], items: [pumpkin])
        stub.setFetchMediaHandler { ids in
            ids.map {
                MediaRow(
                    id: $0, storagePath: "f/original.jpg", type: .photo, width: 4000, height: 3000,
                    thumbPath: "f/thumb.jpg", thumbWidth: 800, thumbHeight: 600, durationSeconds: nil
                )
            }
        }
        let thumbURL = URL(string: "https://example.test/thumb.jpg")!
        stub.setSignedURLsHandler { paths in Dictionary(uniqueKeysWithValues: paths.map { ($0, thumbURL) }) }

        let content = try await assembleOne(record, stub: stub)

        XCTAssertEqual(content.photo?.signedURL, thumbURL)
        XCTAssertEqual(stub.fetchMediaCalls, [[mediaID]])
        XCTAssertEqual(stub.signedURLsCalls, [["f/thumb.jpg"]], "簽縮圖、不簽原圖")
        XCTAssertEqual(FoodFirstCardCopy.sections(for: content), [.head, .note, .photo, .bookRow, .signature])
    }

    /// ③ 只記了日期（沒選反應、沒寫一句話）：反應列與 Note 都隱藏（稿 `A5xBK` `OZHA9`／`MR5Yu` 關閉）。
    /// 純空白的一句話視同沒寫。
    func test_assemble_dateOnly_hidesReactionAndNote() async throws {
        let record = makeRecord(foodID: "pumpkin", day: "2026-02-20", mediaID: nil, note: "  \n", reaction: nil)
        let stub = stubClient(records: [record], items: [pumpkin])

        let content = try await assembleOne(record, stub: stub)

        XCTAssertNil(FoodFirstCardCopy.reaction(content.record))
        XCTAssertNil(FoodFirstCardCopy.note(content.record))
        XCTAssertEqual(FoodFirstCardCopy.sections(for: content), [.head, .bookRow, .signature])
    }

    /// ④ 與同日日記並列：`food_first` 的 `occurred_at` 是 `first_tried_on` 的 UTC 午夜、日記是 `entry_date` 的 UTC
    /// 午夜——同一天就落在同一個 Day Divider 底下（稿 Feed Excerpt `owgBO`），不各自開一天。
    func test_sameDayWithDiary_groupedUnderOneDayDivider() async throws {
        let day = BirthdayFormat.date(fromWireString: "2026-08-20")!
        let record = makeRecord(foodID: "pumpkin", day: "2026-08-20", mediaID: nil, note: nil)
        let diaryID = UUID()
        let stub = stubClient(records: [record], items: [pumpkin])
        stub.setFetchDiariesHandler { _ in [DiaryRow(id: diaryID, body: "去公園", entryDate: day, createdAt: day)] }
        let pointers = [
            TimelineFeedPointer(kind: .foodFirst, refId: record.id, occurredAt: day, childIds: [childID]),
            TimelineFeedPointer(kind: .diary, refId: diaryID, occurredAt: day, childIds: [childID])
        ]

        let entries = try await TimelineContentAssembler.assemble(pointers: pointers, apiClient: stub)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let groups = TimelineDayGrouping.group(entries, calendar: utc)

        XCTAssertEqual(groups.count, 1, "同一天的食物卡與日記卡應共用一個 Day Divider")
        XCTAssertEqual(groups.first?.entries.map(\.kind), [.foodFirst, .diary])
        XCTAssertTrue(entries.allSatisfy { $0.content != nil })
    }

    /// 照片已被軟刪（`media_select` 不回傳）：卡片照樣出現，只是沒有照片區；目錄查不到那項食物才整筆不畫。
    func test_assemble_photoGoneOrItemMissing() async throws {
        let withGonePhoto = makeRecord(foodID: "pumpkin", day: "2025-11-18", mediaID: UUID(), note: nil)
        let unknownFood = makeRecord(foodID: "not_in_catalog", day: "2025-11-19", mediaID: nil, note: nil)
        let stub = stubClient(records: [withGonePhoto, unknownFood], items: [pumpkin])

        let entries = try await TimelineContentAssembler.assemble(
            pointers: [withGonePhoto, unknownFood].map {
                TimelineFeedPointer(kind: .foodFirst, refId: $0.id, occurredAt: $0.firstTriedOn, childIds: [childID])
            },
            apiClient: stub
        )

        guard case .foodFirst(let content) = entries[0].content else { return XCTFail("照片不見仍應有卡片內容") }
        XCTAssertNil(content.photo)
        XCTAssertNil(entries[1].content, "目錄找不到的食物不畫")
    }

    // MARK: - Book Row 導向該類別

    /// Book Row 開的是**這項食物的類別**（優格＝乳製品），不是圖鑑預設的穀物根莖。
    func test_bookRowRoute_opensFoodBookOnItemCategory() {
        let record = makeRecord(foodID: "yogurt", day: "2026-05-02", mediaID: nil, note: nil)
        let content = FoodFirstContent(record: record, item: yogurt, photo: nil)

        XCTAssertEqual(TimelineRoute.foodBook(for: content), .foodBook(childID: childID, category: .dairy))
        XCTAssertEqual(
            FoodFirstCardCopy.bookRowLabel(childName: child.name, category: content.item.category),
            "收進小安的飲食圖鑑 · 乳製品"
        )
    }

    // MARK: - 無互動列

    /// `food_first` 不是 `content_target_type`：不能互動，`refresh` 只替日記查愛心、不送 `food_first`。
    func test_refresh_doesNotQueryReactionCountsForFoodFirst() async {
        let record = makeRecord(foodID: "pumpkin", day: "2026-08-20", mediaID: nil, note: nil)
        let diaryID = UUID()
        let day = record.firstTriedOn
        let stub = stubClient(records: [record], items: [pumpkin])
        stub.setFetchDiariesHandler { _ in [DiaryRow(id: diaryID, body: "x", entryDate: day, createdAt: day)] }
        stub.setFetchPointersHandler { [childID] _, _, _, _ in
            [
                TimelineFeedPointer(kind: .foodFirst, refId: record.id, occurredAt: day, childIds: [childID]),
                TimelineFeedPointer(kind: .diary, refId: diaryID, occurredAt: day, childIds: [childID])
            ]
        }
        let store = TimelineStore(apiClient: stub)

        await store.refresh(familyID: familyID, childID: nil)

        XCTAssertFalse(FeedKind.foodFirst.supportsInteractions)
        XCTAssertEqual(store.entries.count, 2, "食物卡照樣出現在時間軸")
        XCTAssertEqual(stub.reactionCountsCalls.map(\.targetType), ["diary"], "不替 food_first 查愛心計數")
    }

    // MARK: - 文案與署名

    func test_copy_headlineAndSignatureAgeAsOfFirstTriedDay() {
        XCTAssertEqual(FoodFirstCardCopy.headline(foodName: "南瓜"), "第一次吃到南瓜")
        let firstTriedOn = BirthdayFormat.date(fromWireString: "2025-10-20")!
        let parts = FoodFirstCardCopy.signature(child: child, firstTriedOn: firstTriedOn)
        XCTAssertEqual(parts.name, "小安")
        // 年齡＝第一次吃那天（6 個月大），不是今天；「·」後與年齡內 U+00A0、「個⁠月⁠大」U+2060（LS-367 規則同源）。
        XCTAssertEqual(parts.age, " ·\u{00A0}6\u{00A0}個\u{2060}月\u{2060}大")
    }

    // MARK: - helpers

    private func makeRecord(
        foodID: String, day: String, mediaID: UUID?, note: String?, reaction: String? = "liked"
    ) -> ChildFoodRecord {
        let date = BirthdayFormat.date(fromWireString: day)!
        return ChildFoodRecord(
            id: UUID(), familyID: familyID, childID: childID, foodID: foodID, authorID: nil, firstTriedOn: date,
            mediaID: mediaID, note: note, reaction: reaction, createdAt: date, updatedAt: date
        )
    }

    private func stubClient(records: [ChildFoodRecord], items: [FoodCatalogItem]) -> StubTimelineAPIClient {
        let stub = StubTimelineAPIClient()
        stub.setFetchFoodRecordsHandler { ids in records.filter { ids.contains($0.id) } }
        stub.setFetchFoodCatalogItemsHandler { ids in items.filter { ids.contains($0.id) } }
        return stub
    }

    private func assembleOne(_ record: ChildFoodRecord, stub: StubTimelineAPIClient) async throws -> FoodFirstContent {
        let entries = try await TimelineContentAssembler.assemble(
            pointers: [TimelineFeedPointer(
                kind: .foodFirst, refId: record.id, occurredAt: record.firstTriedOn, childIds: [childID]
            )],
            apiClient: stub
        )
        XCTAssertEqual(entries.map(\.kind), [.foodFirst])
        guard case .foodFirst(let content) = entries.first?.content else {
            XCTFail("food_first 應組裝出食物卡內容")
            throw CancellationError()
        }
        return content
    }
}

import Foundation
@testable import LittleSprout
import XCTest

/// LS-381：`FoodRecordDetailStore.refresh()`——詳情開著時記錄的最新狀態。
///
/// 鎖住的行為（自檢 R1 race）：
/// - 記錄被刪（owner 刪了別人的、作者在另一台刪了）→ `isGone`，畫面據此返回圖鑑，不停在一筆不存在的記錄上。
/// - 記錄被改過 → 用最新那筆（反應／備註）；照片換了 → 補簽新照片，不留舊照片。
/// - 重讀失敗 → 保留手上那筆＋`refreshError`（錯誤列），照片／記錄者照常顯示。
@MainActor
final class FoodRecordDetailStoreTests: XCTestCase {
    private final class StubFoodAPIClient: FoodAPIClient, @unchecked Sendable {
        var recordsResult: Result<[ChildFoodRecord], Error>

        init(records: [ChildFoodRecord]) {
            recordsResult = .success(records)
        }

        func listFoodCatalog() async throws -> [FoodCatalogItem] { [] }

        func listChildFoodRecords(childID: UUID) async throws -> [ChildFoodRecord] { try recordsResult.get() }

        // LS-380 的寫入／照片方法：詳情 store 不呼叫它們，被呼叫到就是測試寫錯，大聲失敗。
        func upsertChildFoodRecord(_ input: FoodRecordUpsert) async throws -> ChildFoodRecord { throw Unused() }
        func deleteChildFoodRecord(id: UUID) async throws { throw Unused() }
        func listFamilyPhotos(childID: UUID) async throws -> [FamilyPhoto] { throw Unused() }
        func fetchFamilyPhoto(id: UUID) async throws -> FamilyPhoto? { throw Unused() }
        func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] { throw Unused() }
        func uploadPhoto(childID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
            throw Unused()
        }
    }

    private struct Unused: Error {}

    private final class StubDetailAPIClient: FoodRecordDetailAPIClient, @unchecked Sendable {
        var names: [UUID: String] = [:]
        /// 前幾次 `photoURL` 回 nil（簽名網址拿不到），之後才成功。
        var failuresBeforeSuccess = 0
        private(set) var photoRequests: [UUID] = []

        func photoURL(mediaID: UUID) async throws -> URL? {
            photoRequests.append(mediaID)
            return photoRequests.count > failuresBeforeSuccess ? Self.url(for: mediaID) : nil
        }

        func displayName(userID: UUID) async throws -> String? { names[userID] }

        static func url(for mediaID: UUID) -> URL {
            URL(string: "https://example.test/\(mediaID.uuidString).jpg")!
        }
    }

    private let author = UUID()

    private func record(
        id: UUID = UUID(), mediaID: UUID?, note: String? = nil, reaction: String? = nil
    ) throws -> ChildFoodRecord {
        let date = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2026-06-08"))
        return ChildFoodRecord(
            id: id, familyID: UUID(), childID: UUID(), foodID: "bread", authorID: author, firstTriedOn: date,
            mediaID: mediaID, note: note, reaction: reaction, createdAt: date, updatedAt: date
        )
    }

    func test_refresh_loadsPhotoAndAuthorName() async throws {
        let mediaID = UUID()
        let original = try record(mediaID: mediaID)
        let detail = StubDetailAPIClient()
        detail.names = [author: "媽媽"]
        let store = FoodRecordDetailStore(
            record: original, foodAPIClient: StubFoodAPIClient(records: [original]), detailAPIClient: detail
        )
        XCTAssertEqual(store.photo, .loading, "有 media_id：第一幀是照片窗空白，不是 04b 的加照片邀請")

        await store.refresh()

        XCTAssertEqual(store.photo, .loaded(StubDetailAPIClient.url(for: mediaID)))
        XCTAssertEqual(store.authorName, "媽媽")
        XCTAssertFalse(store.isGone)
        XCTAssertNil(store.refreshError)
    }

    func test_refresh_recordDeletedElsewhere_marksGone() async throws {
        let original = try record(mediaID: nil)
        let store = FoodRecordDetailStore(
            record: original, foodAPIClient: StubFoodAPIClient(records: []), detailAPIClient: StubDetailAPIClient()
        )

        await store.refresh()

        XCTAssertTrue(store.isGone, "未刪列表裡沒有這筆＝已被軟刪，詳情要返回圖鑑")
    }

    func test_refresh_recordEditedElsewhere_showsLatestAndResignsNewPhoto() async throws {
        let recordID = UUID(), oldMedia = UUID(), newMedia = UUID()
        let original = try record(id: recordID, mediaID: oldMedia, note: "舊", reaction: "neutral")
        let edited = try record(id: recordID, mediaID: newMedia, note: "新", reaction: "liked")
        let detail = StubDetailAPIClient()
        let store = FoodRecordDetailStore(
            record: original, foodAPIClient: StubFoodAPIClient(records: [edited]), detailAPIClient: detail
        )

        await store.refresh()

        XCTAssertEqual(store.record.note, "新")
        XCTAssertEqual(store.record.reaction, "liked")
        XCTAssertEqual(store.photo, .loaded(StubDetailAPIClient.url(for: newMedia)), "照片換了：不能留舊照片")
        XCTAssertEqual(detail.photoRequests.last, newMedia)
    }

    func test_refresh_photoRemovedElsewhere_fallsBackToBlankPrint() async throws {
        let recordID = UUID()
        let original = try record(id: recordID, mediaID: UUID())
        let edited = try record(id: recordID, mediaID: nil)
        let store = FoodRecordDetailStore(
            record: original, foodAPIClient: StubFoodAPIClient(records: [edited]),
            detailAPIClient: StubDetailAPIClient()
        )

        await store.refresh()

        XCTAssertEqual(store.photo, .none, "作者按了「不用照片」→ 04b 空白沖印品")
    }

    func test_refresh_failure_keepsRecordAndPhotoAndReportsError() async throws {
        let mediaID = UUID()
        let original = try record(mediaID: mediaID, note: "自己抓著吃")
        let food = StubFoodAPIClient(records: [])
        food.recordsResult = .failure(AppError.network(message: "offline"))
        let store = FoodRecordDetailStore(record: original, foodAPIClient: food, detailAPIClient: StubDetailAPIClient())

        await store.refresh()

        XCTAssertFalse(store.isGone, "讀取失敗≠被刪")
        XCTAssertEqual(store.record, original)
        XCTAssertEqual(store.refreshError, .network(message: "offline"))
        XCTAssertEqual(store.photo, .loaded(StubDetailAPIClient.url(for: mediaID)), "照片與記錄重讀各自獨立")
    }

    func test_photoWithoutAccess_isUnavailableNotBlankPrint() async throws {
        let original = try record(mediaID: UUID())
        let store = FoodRecordDetailStore(
            record: original, foodAPIClient: StubFoodAPIClient(records: [original]), detailAPIClient: nil
        )

        await store.refresh()

        XCTAssertEqual(store.photo, .unavailable, "有 media_id 但看不到：空白照片窗，不邀請加照片")
    }

    // MARK: - LS-380 接縫⑦：編輯後回詳情頁換新

    /// 03b 儲存後呼叫端帶進更新過的同一筆：`adopt` 先換上（照片換了回 `.loading`），舊值（`updatedAt` 沒比較新）
    /// 一律忽略、不倒退。
    func test_adopt_takesNewerSameRecordOnly() async throws {
        let original = try record(mediaID: UUID(), reaction: "liked")
        let store = FoodRecordDetailStore(
            record: original, foodAPIClient: StubFoodAPIClient(records: [original]),
            detailAPIClient: StubDetailAPIClient()
        )
        await store.refresh()
        XCTAssertEqual(store.photo, .loaded(StubDetailAPIClient.url(for: original.mediaID!)))

        let edited = ChildFoodRecord(
            id: original.id, familyID: original.familyID, childID: original.childID, foodID: original.foodID,
            authorID: original.authorID, firstTriedOn: original.firstTriedOn, mediaID: nil, note: "改過",
            reaction: "neutral", createdAt: original.createdAt, updatedAt: original.updatedAt.addingTimeInterval(60)
        )
        store.adopt(edited)
        XCTAssertEqual(store.record.reaction, "neutral", "比較新的同一筆要換上")
        XCTAssertEqual(store.photo, .none, "照片拿掉了：回到 04b 空白沖印品")

        store.adopt(original)
        XCTAssertEqual(store.record.reaction, "neutral", "舊值不能把畫面倒退回去")
    }

    // MARK: - LS-383 R2（LS-380 R2 m1，池 c712c880）：只有最新一次 refresh 能寫回

    /// 首次重讀還沒回來時，使用者在 04b 存好新照片：`.task(id: record)` 取消舊的一輪、新的一輪先 `adopt` 再
    /// `refresh`。舊寫法以 `isRefreshing` 早退，新一輪被擋、舊一輪又因取消不寫回——照片窗永遠停在 `.loading`。
    /// 重現步驟同 reviewer probe（`LS-380-rv2-probe.log`）。
    func test_refresh_newPhotoSavedWhileFirstRefreshPending_photoDoesNotStickLoading() async throws {
        let original = try record(mediaID: nil)
        let newMedia = UUID()
        let saved = ChildFoodRecord(
            id: original.id, familyID: original.familyID, childID: original.childID, foodID: original.foodID,
            authorID: original.authorID, firstTriedOn: original.firstTriedOn, mediaID: newMedia, note: nil,
            reaction: nil, createdAt: original.createdAt, updatedAt: original.updatedAt.addingTimeInterval(60)
        )
        let client = BlockingFirstListClient(records: [saved])
        let store = FoodRecordDetailStore(
            record: original, foodAPIClient: client, detailAPIClient: StubDetailAPIClient()
        )

        let firstTask = Task { await store.refresh() }
        while client.gate == nil { await Task.yield() }
        firstTask.cancel()
        store.adopt(saved)
        XCTAssertEqual(store.photo, .loading)
        await store.refresh()
        client.gate?.resume()
        await firstTask.value

        XCTAssertEqual(store.photo, .loaded(StubDetailAPIClient.url(for: newMedia)), "照片不該停在 loading")
        XCTAssertFalse(store.isRefreshing)
    }

    /// R3（merge-review R2 i5）：兩輪都沒被取消——舊的一輪（伺服器快照是存檔前的「喜歡」）晚於新的一輪回來，
    /// 不得把新一輪寫好的「普通」蓋回去。釘住的是世代號比對本身（`FoodRecordDetailStore.refresh()` 的
    /// `generation == refreshGeneration`），不靠取消。
    func test_refresh_staleEarlierRoundReturnsLate_doesNotOverwriteNewerResult() async throws {
        let original = try record(mediaID: nil, reaction: "liked")
        let edited = ChildFoodRecord(
            id: original.id, familyID: original.familyID, childID: original.childID, foodID: original.foodID,
            authorID: original.authorID, firstTriedOn: original.firstTriedOn, mediaID: nil, note: "改過",
            reaction: "neutral", createdAt: original.createdAt, updatedAt: original.updatedAt.addingTimeInterval(60)
        )
        let client = BlockingFirstListClient(records: [edited], firstRecords: [original])
        let store = FoodRecordDetailStore(
            record: original, foodAPIClient: client, detailAPIClient: StubDetailAPIClient()
        )

        let firstRound = Task { await store.refresh() }
        while client.gate == nil { await Task.yield() }
        await store.refresh()
        XCTAssertEqual(store.record.reaction, "neutral", "新的一輪先回來，寫上最新值")
        client.gate?.resume()
        await firstRound.value

        XCTAssertEqual(store.record.reaction, "neutral", "晚回來的舊一輪不得把最新值蓋回「喜歡」")
        XCTAssertEqual(store.record.note, "改過")
    }

    /// 第一次 `listChildFoodRecords` 卡住（等測試放行）並回傳 `firstRecords`（沒給就同 `records`），之後的呼叫
    /// 立刻回傳 `records`——模擬「首次重讀還在路上」。
    private final class BlockingFirstListClient: FoodAPIClient, @unchecked Sendable {
        let records: [ChildFoodRecord]
        let firstRecords: [ChildFoodRecord]
        var gate: CheckedContinuation<Void, Never>?
        private var blocks = true

        init(records: [ChildFoodRecord], firstRecords: [ChildFoodRecord]? = nil) {
            self.records = records
            self.firstRecords = firstRecords ?? records
        }

        func listFoodCatalog() async throws -> [FoodCatalogItem] { [] }
        func listChildFoodRecords(childID: UUID) async throws -> [ChildFoodRecord] {
            if blocks {
                blocks = false
                await withCheckedContinuation { gate = $0 }
                return firstRecords
            }
            return records
        }
        func upsertChildFoodRecord(_ input: FoodRecordUpsert) async throws -> ChildFoodRecord { throw Unused() }
        func deleteChildFoodRecord(id: UUID) async throws { throw Unused() }
        func listFamilyPhotos(childID: UUID) async throws -> [FamilyPhoto] { throw Unused() }
        func fetchFamilyPhoto(id: UUID) async throws -> FamilyPhoto? { throw Unused() }
        func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] { throw Unused() }
        func uploadPhoto(childID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
            throw Unused()
        }
    }

    // MARK: - LS-380 R3：router 顯示的那一筆

    /// QA `a27eafaf`：真入口下呼叫端的記錄推入後不再更新——router 必須以自己存過的較新那筆為準；呼叫端之後若帶來
    /// 更新的值（或換了一筆）則以呼叫端為準。
    @MainActor
    func test_shownRecord_prefersNewerSavedSameRecord() throws {
        let caller = try record(mediaID: nil, reaction: "liked")
        func copy(_ base: ChildFoodRecord, reaction: String, plus seconds: TimeInterval) -> ChildFoodRecord {
            ChildFoodRecord(
                id: base.id, familyID: base.familyID, childID: base.childID, foodID: base.foodID,
                authorID: base.authorID, firstTriedOn: base.firstTriedOn, mediaID: base.mediaID, note: base.note,
                reaction: reaction,
                createdAt: base.createdAt, updatedAt: base.updatedAt.addingTimeInterval(seconds)
            )
        }
        let saved = copy(caller, reaction: "disliked", plus: 10)
        XCTAssertEqual(FoodRecordDetailRouter.shownRecord(caller: caller, saved: nil), caller)
        XCTAssertEqual(FoodRecordDetailRouter.shownRecord(caller: caller, saved: saved), saved, "呼叫端沒更新：用存好的")
        let callerLater = copy(caller, reaction: "neutral", plus: 20)
        XCTAssertEqual(
            FoodRecordDetailRouter.shownRecord(caller: callerLater, saved: saved), callerLater, "呼叫端較新：用呼叫端"
        )
        let other = try record(mediaID: nil, reaction: "liked")
        XCTAssertEqual(FoodRecordDetailRouter.shownRecord(caller: other, saved: saved), other, "不同筆：用呼叫端")
    }
}

// 拆出 extension：class body 逼近 SwiftLint `type_body_length`（250）上限。
extension FoodRecordDetailStoreTests {
    // MARK: - LS-434 04e「再試一次」

    /// 04e：簽名網址第一次拿不到 → `.unavailable`；`retryPhoto()` 重讀後拿到 → `.loaded`（「再試一次」真的會重載）。
    func test_retryPhoto_fromUnavailable_loadsPhotoWhenSecondRequestSucceeds() async throws {
        let mediaID = UUID()
        let original = try record(mediaID: mediaID)
        let detail = StubDetailAPIClient()
        detail.failuresBeforeSuccess = 1
        let store = FoodRecordDetailStore(
            record: original, foodAPIClient: StubFoodAPIClient(records: [original]), detailAPIClient: detail
        )
        await store.refresh()
        XCTAssertEqual(store.photo, .unavailable)
        XCTAssertEqual(detail.photoRequests.count, 1)

        await store.retryPhoto()

        XCTAssertEqual(store.photo, .loaded(StubDetailAPIClient.url(for: mediaID)), "重試成功要換成照片")
        XCTAssertEqual(detail.photoRequests.count, 2, "重試真的發了一次請求")
    }

    /// C2a：已刪照片再試也不會成功——回到 `.unavailable`，不另外分辨成別的態。
    func test_retryPhoto_whenStillFailing_staysUnavailable() async throws {
        let original = try record(mediaID: UUID())
        let detail = StubDetailAPIClient()
        detail.failuresBeforeSuccess = 99
        let store = FoodRecordDetailStore(
            record: original, foodAPIClient: StubFoodAPIClient(records: [original]), detailAPIClient: detail
        )
        await store.refresh()

        await store.retryPhoto()

        XCTAssertEqual(store.photo, .unavailable)
        XCTAssertEqual(detail.photoRequests.count, 2, "有重試（兩次請求），結果仍是失敗態")
    }

    /// 連點保護：不在 `.unavailable`（載入成功、沒有照片）時 `retryPhoto()` 不發任何請求、不改狀態。
    func test_retryPhoto_whenNotUnavailable_sendsNoRequest() async throws {
        let mediaID = UUID()
        let original = try record(mediaID: mediaID)
        let detail = StubDetailAPIClient()
        let store = FoodRecordDetailStore(
            record: original, foodAPIClient: StubFoodAPIClient(records: [original]), detailAPIClient: detail
        )
        await store.refresh()
        XCTAssertEqual(store.photo, .loaded(StubDetailAPIClient.url(for: mediaID)))
        let requestsBefore = detail.photoRequests.count

        await store.retryPhoto()

        XCTAssertEqual(detail.photoRequests.count, requestsBefore, "已載入：不重送請求")
        XCTAssertEqual(store.photo, .loaded(StubDetailAPIClient.url(for: mediaID)))

        let blank = try record(mediaID: nil)
        let blankStore = FoodRecordDetailStore(
            record: blank, foodAPIClient: StubFoodAPIClient(records: [blank]), detailAPIClient: detail
        )
        await blankStore.retryPhoto()
        XCTAssertEqual(detail.photoRequests.count, requestsBefore, "沒有照片（04b／04d）：不發請求")
        XCTAssertEqual(blankStore.photo, .none)
    }
}

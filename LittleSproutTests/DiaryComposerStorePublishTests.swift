import Foundation
@testable import LittleSprout
import os
import XCTest

/// `DiaryComposerStore.publish()` 送出流程：空內文提示（不借用失敗態）、成功依序上傳＋建立
/// ＋掛 media、API 失敗草稿不清空、進行中擋重複呼叫、照片還在載入時擋下送出（M3）、不支援
/// 格式的常駐回話（m4）。跟 `DiaryComposerStoreTests`（佇列／選取／排序／歸屬）分開檔案，
/// 理由見該檔文件註解；重試路徑（M2／R2 N1／R2 n2）另外拆到
/// `DiaryComposerStorePublishRetryTests`，理由見該檔文件註解。
@MainActor
final class DiaryComposerStorePublishTests: XCTestCase {
    private let familyID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let childA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    private func makeStore(
        diaryAPIClient: StubDiaryAPIClient = StubDiaryAPIClient(),
        mediaUploadService: StubMediaUploadService = StubMediaUploadService()
    ) -> DiaryComposerStore {
        DiaryComposerStore(familyID: familyID, diaryAPIClient: diaryAPIClient, mediaUploadService: mediaUploadService)
    }

    @discardableResult
    private func addPhoto(_ store: DiaryComposerStore, tag: String = "a") -> DiaryPhotoAddOutcome {
        store.addPhoto(
            data: Data(tag.utf8), fileExtension: "jpg", pixelSize: PixelSize(width: 100, height: 100), previewImage: nil
        )
    }

    // MARK: - 空內文（merge-review R1 M1／m10：不借用 12c 失敗態）

    func test_publish_emptyBody_showsInlineMessageWithoutTouchingPublishStateOrCallingAPI() async {
        let diaryClient = StubDiaryAPIClient()
        let store = makeStore(diaryAPIClient: diaryClient)
        store.body = "   "

        let result = await store.publish()

        XCTAssertFalse(result)
        XCTAssertTrue(store.showsEmptyBodyMessage)
        XCTAssertEqual(store.publishState, .idle, "空內文不是送出失敗，不該借用 12c 的 .failure 狀態")
        XCTAssertTrue(diaryClient.createCalls.isEmpty, "驗證失敗不該打任何 API")
    }

    func test_publish_bodyBecomesNonEmpty_clearsEmptyBodyMessage() async {
        let store = makeStore()
        store.body = "   "
        _ = await store.publish()
        XCTAssertTrue(store.showsEmptyBodyMessage)

        store.body = "現在有內容了"

        XCTAssertFalse(store.showsEmptyBodyMessage)
    }

    // MARK: - 成功路徑

    func test_publish_success_uploadsPhotosInOrderThenCreatesEntryThenAttachesMedia() async {
        let diaryClient = StubDiaryAPIClient()
        let mediaService = StubMediaUploadService()
        let firstMediaID = UUID()
        let secondMediaID = UUID()
        let uploadedIDs = OSAllocatedUnfairLockBox([firstMediaID, secondMediaID])
        mediaService.setUploadPhotoHandler { _, _, _, _ in uploadedIDs.popFirst() }
        let newDiaryID = UUID()
        diaryClient.setCreateHandler { _, _, _, _ in newDiaryID }

        let store = makeStore(diaryAPIClient: diaryClient, mediaUploadService: mediaService)
        store.body = "今天玩得很開心"
        store.selectedChildIDs = [childA]
        addPhoto(store, tag: "first")
        addPhoto(store, tag: "second")

        let result = await store.publish()

        XCTAssertTrue(result)
        XCTAssertEqual(store.publishState, .success)
        XCTAssertEqual(mediaService.uploadPhotoCalls.count, 2)
        XCTAssertEqual(diaryClient.createCalls.count, 1)
        XCTAssertEqual(diaryClient.createCalls.first?.body, "今天玩得很開心")
        XCTAssertEqual(diaryClient.createCalls.first?.childIDs, [childA])
        XCTAssertEqual(diaryClient.attachMediaCalls.count, 1)
        XCTAssertEqual(diaryClient.attachMediaCalls.first?.diaryID, newDiaryID)
        XCTAssertEqual(
            diaryClient.attachMediaCalls.first?.mediaIDs, [firstMediaID, secondMediaID], "掛照片的順序要跟佇列順序一致"
        )
    }

    func test_publish_unspecifiedChild_sendsEmptyChildIDs() async {
        let diaryClient = StubDiaryAPIClient()
        let store = makeStore(diaryAPIClient: diaryClient)
        store.body = "沒有指定寶貝"

        _ = await store.publish()

        XCTAssertEqual(diaryClient.createCalls.first?.childIDs, [])
    }

    // MARK: - 失敗（草稿不清空、擋重複呼叫、失敗態隨內容變更重置）

    func test_publish_apiFailure_preservesDraftContent() async {
        let diaryClient = StubDiaryAPIClient()
        diaryClient.setCreateHandler { _, _, _, _ in throw AppError.network(message: "offline") }
        let store = makeStore(diaryAPIClient: diaryClient)
        store.body = "你寫的內容還在"
        addPhoto(store)

        let result = await store.publish()

        XCTAssertFalse(result)
        XCTAssertEqual(store.publishState, .failure(.network(message: "offline")))
        XCTAssertEqual(store.body, "你寫的內容還在", "12c：失敗後草稿內容不可被清空")
        XCTAssertEqual(store.photos.count, 1, "12c：失敗後照片佇列不可被清空")
    }

    func test_publish_whileInFlight_ignoresDuplicateCall() async {
        let diaryClient = StubDiaryAPIClient()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        diaryClient.setCreateHandler { _, _, _, _ in
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return UUID()
        }
        let store = makeStore(diaryAPIClient: diaryClient)
        store.body = "內容"

        let firstTask = Task { await store.publish() }
        var guardIterations = 0
        while !store.publishState.isInFlight {
            guardIterations += 1
            guard guardIterations < 200 else {
                gateContinuation.finish()
                return XCTFail("等待 publishState 進入 .uploading 逾時")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let duplicateResult = await store.publish()
        XCTAssertFalse(duplicateResult, "送出進行中時重複呼叫應該被擋下")

        gateContinuation.finish()
        _ = await firstTask.value
        XCTAssertEqual(diaryClient.createCalls.count, 1)
    }

    func test_resetPublishFailure_onlyResetsFromFailure() async {
        let diaryClient = StubDiaryAPIClient()
        diaryClient.setCreateHandler { _, _, _, _ in throw AppError.network(message: "offline") }
        let store = makeStore(diaryAPIClient: diaryClient)
        store.body = "內容"
        _ = await store.publish()

        store.resetPublishFailure()
        XCTAssertEqual(store.publishState, .idle)

        store.resetPublishFailure()
        XCTAssertEqual(store.publishState, .idle, "非 .failure 狀態呼叫應該是 no-op")
    }

    /// merge-review R1 m5：`resetPublishFailure` 先前沒有任何呼叫端，現在接上 `body` 的
    /// `didSet`——12c 失敗後使用者開始改內容，舊的失敗態要先收掉。
    func test_bodyChange_whileInFailureState_resetsPublishState() async {
        let diaryClient = StubDiaryAPIClient()
        diaryClient.setCreateHandler { _, _, _, _ in throw AppError.network(message: "offline") }
        let store = makeStore(diaryAPIClient: diaryClient)
        store.body = "內容"
        _ = await store.publish()
        XCTAssertEqual(store.publishState, .failure(.network(message: "offline")))

        store.body = "內容，改過了"

        XCTAssertEqual(store.publishState, .idle)
    }

    // MARK: - 照片還在載入時擋下送出（merge-review R1 M3）

    func test_publish_whileLoadingPickedItems_isBlocked() async {
        let diaryClient = StubDiaryAPIClient()
        let store = makeStore(diaryAPIClient: diaryClient)
        store.body = "內容"
        store.beginLoadingPickedItems()

        let result = await store.publish()

        XCTAssertFalse(result, "照片還在背景解碼時發佈應該被擋下，否則會靜默漏掉還沒 append 完成的照片")
        XCTAssertTrue(diaryClient.createCalls.isEmpty)
    }

    func test_publish_afterLoadingPickedItemsEnds_succeeds() async {
        let diaryClient = StubDiaryAPIClient()
        let store = makeStore(diaryAPIClient: diaryClient)
        store.body = "內容"
        store.beginLoadingPickedItems()
        store.endLoadingPickedItems()

        let result = await store.publish()

        XCTAssertTrue(result)
    }

    // MARK: - 不支援格式的常駐回話（merge-review R1 m4）

    func test_reportUnsupportedFormatSkipped_accumulatesCount() {
        let store = makeStore()
        store.reportUnsupportedFormatSkipped(count: 2)
        XCTAssertEqual(store.unsupportedFormatSkippedCount, 2)
    }

    func test_beginLoadingPickedItems_resetsUnsupportedFormatCount() {
        let store = makeStore()
        store.reportUnsupportedFormatSkipped(count: 2)

        store.beginLoadingPickedItems()

        XCTAssertEqual(store.unsupportedFormatSkippedCount, 0, "新一批挑選開始時，上一批的提示不該留著")
    }
}

/// `test_publish_success_...` 需要一個執行緒安全、可以依序彈出預先準備好的假 id 的小容器
/// （模擬「第一次呼叫回第一個 id、第二次回第二個」），驗證掛照片的順序真的對應佇列順序。
private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[UUID]>(initialState: [])

    init(_ values: [UUID]) {
        lock.withLock { $0 = values }
    }

    func popFirst() -> UUID {
        lock.withLock { state in
            guard !state.isEmpty else { return UUID() }
            return state.removeFirst()
        }
    }
}

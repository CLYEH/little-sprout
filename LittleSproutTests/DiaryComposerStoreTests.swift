import Foundation
@testable import LittleSprout
import os
import XCTest

/// `DiaryComposerStore`（LS-125 日記編輯器狀態機）：佇列容量／選取移除／拖曳排序／VoiceOver
/// 邊界／寶貝歸屬互斥／送出流程（成功／驗證失敗／API 失敗時草稿不清空）。
@MainActor
final class DiaryComposerStoreTests: XCTestCase {
    private let familyID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let childA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let childB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

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

    // MARK: - 佇列容量（20 張上限，Scope 2）

    func test_addPhoto_upToCapacity_allAdded_thenCapacityReached() {
        let store = makeStore()
        for _ in 0..<DiaryComposerStore.photoCapacity {
            XCTAssertEqual(addPhoto(store), .added)
        }
        XCTAssertEqual(store.photos.count, DiaryComposerStore.photoCapacity)
        XCTAssertTrue(store.isAtCapacity)
        XCTAssertEqual(store.remainingSlots, 0)

        XCTAssertEqual(addPhoto(store), .capacityReached)
        XCTAssertEqual(store.photos.count, DiaryComposerStore.photoCapacity, "第 21 張不應該被加進佇列")
    }

    func test_remainingSlots_decreasesAsPhotosAdded() {
        let store = makeStore()
        XCTAssertEqual(store.remainingSlots, 20)
        addPhoto(store)
        XCTAssertEqual(store.remainingSlots, 19)
    }

    // MARK: - 影片超過 60 秒（12g）

    func test_overLongVideoDrafts_onlyIncludesVideosPast60Seconds() {
        let store = makeStore()
        store.addVideo(
            fileURL: URL(fileURLWithPath: "/tmp/short.mp4"), fileExtension: "mp4", duration: 32,
            pixelSize: PixelSize(width: 100, height: 100), previewImage: nil
        )
        store.addVideo(
            fileURL: URL(fileURLWithPath: "/tmp/long.mp4"), fileExtension: "mp4", duration: 84,
            pixelSize: PixelSize(width: 100, height: 100), previewImage: nil
        )
        addPhoto(store)

        XCTAssertEqual(store.overLongVideoDrafts.count, 1)
        XCTAssertEqual(store.overLongVideoDrafts.first?.videoDuration, 84)
    }

    // MARK: - 選取／移除（12d）

    func test_toggleSelection_addsAndRemoves() {
        let store = makeStore()
        addPhoto(store)
        let id = store.photos[0].id

        store.toggleSelection(id)
        XCTAssertTrue(store.isSelected(id))
        XCTAssertEqual(store.selectedPhotoIDs, [id])

        store.toggleSelection(id)
        XCTAssertFalse(store.isSelected(id))
        XCTAssertTrue(store.selectedPhotoIDs.isEmpty)
    }

    func test_removeSelected_removesOnlySelectedAndClearsSelection() {
        let store = makeStore()
        addPhoto(store, tag: "a")
        addPhoto(store, tag: "b")
        addPhoto(store, tag: "c")
        let keepID = store.photos[1].id
        store.toggleSelection(store.photos[0].id)
        store.toggleSelection(store.photos[2].id)

        store.removeSelected()

        XCTAssertEqual(store.photos.map(\.id), [keepID])
        XCTAssertTrue(store.selectedPhotoIDs.isEmpty)
    }

    func test_removeSelected_emptySelection_isNoOp() {
        let store = makeStore()
        addPhoto(store)
        store.removeSelected()
        XCTAssertEqual(store.photos.count, 1)
    }

    // MARK: - 拖曳排序（12e，放開才落定）

    func test_move_reordersToTargetIndex() {
        let store = makeStore()
        addPhoto(store, tag: "a")
        addPhoto(store, tag: "b")
        addPhoto(store, tag: "c")
        let firstID = store.photos[0].id

        store.move(id: firstID, toIndex: 2)

        XCTAssertEqual(store.photos.last?.id, firstID)
        XCTAssertEqual(store.photos.count, 3)
    }

    func test_move_targetIndexOutOfBounds_isClamped() {
        let store = makeStore()
        addPhoto(store, tag: "a")
        addPhoto(store, tag: "b")
        let firstID = store.photos[0].id

        store.move(id: firstID, toIndex: 999)

        XCTAssertEqual(store.photos.last?.id, firstID, "越界的 toIndex 應該被夾住，不應該 crash 或丟資料")
        XCTAssertEqual(store.photos.count, 2)
    }

    // MARK: - VoiceOver 往前移／往後移（`v0tLp` R6，邊界安靜不動作）

    func test_moveEarlier_atFirstPosition_isNoOp() {
        let store = makeStore()
        addPhoto(store, tag: "a")
        addPhoto(store, tag: "b")
        let order = store.photos.map(\.id)

        store.moveEarlier(order[0])

        XCTAssertEqual(store.photos.map(\.id), order)
    }

    func test_moveEarlier_movesTowardFront() {
        let store = makeStore()
        addPhoto(store, tag: "a")
        addPhoto(store, tag: "b")
        let order = store.photos.map(\.id)

        store.moveEarlier(order[1])

        XCTAssertEqual(store.photos.map(\.id), [order[1], order[0]])
    }

    func test_moveLater_atLastPosition_isNoOp() {
        let store = makeStore()
        addPhoto(store, tag: "a")
        addPhoto(store, tag: "b")
        let order = store.photos.map(\.id)

        store.moveLater(order[1])

        XCTAssertEqual(store.photos.map(\.id), order)
    }

    // MARK: - 寶貝歸屬（`zgVn0`：不指定＝空集合，互斥）

    func test_isUnspecifiedChild_trueWhenEmpty_falseAfterToggle() {
        let store = makeStore()
        XCTAssertTrue(store.isUnspecifiedChild)

        store.toggleChild(childA)
        XCTAssertFalse(store.isUnspecifiedChild)
        XCTAssertEqual(store.selectedChildIDs, [childA])
    }

    func test_toggleChild_multiSelect_bothRetained() {
        let store = makeStore()
        store.toggleChild(childA)
        store.toggleChild(childB)
        XCTAssertEqual(store.selectedChildIDs, [childA, childB])
    }

    func test_selectUnspecifiedChild_clearsExistingSelection() {
        let store = makeStore()
        store.toggleChild(childA)
        store.toggleChild(childB)

        store.selectUnspecifiedChild()

        XCTAssertTrue(store.isUnspecifiedChild)
        XCTAssertTrue(store.selectedChildIDs.isEmpty)
    }

    func test_toggleChild_deselectingLastChild_returnsToUnspecified() {
        let store = makeStore()
        store.toggleChild(childA)
        store.toggleChild(childA)
        XCTAssertTrue(store.isUnspecifiedChild, "移除最後一個選中的寶貝後應自動回到不指定狀態")
    }

    // MARK: - 送出（publish）

    func test_publish_emptyBody_failsValidationWithoutCallingAPI() async {
        let diaryClient = StubDiaryAPIClient()
        let store = makeStore(diaryAPIClient: diaryClient)
        store.body = "   "

        let result = await store.publish()

        XCTAssertFalse(result)
        guard case .failure(let error) = store.publishState else {
            return XCTFail("空白內文應該落在 .failure")
        }
        guard case .validationRetryable = error else {
            return XCTFail("空白內文應該映射為 .validationRetryable，實際是 \(error)")
        }
        XCTAssertTrue(diaryClient.createCalls.isEmpty, "驗證失敗不該打任何 API")
    }

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
        store.toggleChild(childA)
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
        XCTAssertEqual(diaryClient.attachMediaCalls.first?.mediaIDs, [firstMediaID, secondMediaID], "掛照片的順序要跟佇列順序一致")
    }

    func test_publish_unspecifiedChild_sendsEmptyChildIDs() async {
        let diaryClient = StubDiaryAPIClient()
        let store = makeStore(diaryAPIClient: diaryClient)
        store.body = "沒有指定寶貝"

        _ = await store.publish()

        XCTAssertEqual(diaryClient.createCalls.first?.childIDs, [])
    }

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

import Foundation
@testable import LittleSprout
import XCTest

/// `DiaryComposerStore`（LS-125 日記編輯器狀態機）：佇列容量／選取移除／拖曳排序／VoiceOver
/// 邊界／寶貝歸屬互斥。送出流程（`publish()`）測試在 `DiaryComposerStorePublishTests.swift`
/// （拆檔理由：本檔加上送出流程測試會超過 SwiftLint `type_body_length`/`file_length`）。
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
    //
    // merge-review R1 m5：`toggleChild`／`selectUnspecifiedChild` 兩支 store 方法已移除
    // ——`AttributionSheet` 是通用元件，互斥切換邏輯就地寫在它自己收到的 `Binding<Set<UUID>>`
    // 上（見該檔 `toggle(_:)`），從未呼叫過 store 這兩支方法，是新引入的死碼。這裡直接對
    // `selectedChildIDs` 賦值，測的是 `isUnspecifiedChild` 這個真正被 UI 讀取的計算屬性。

    func test_isUnspecifiedChild_trueWhenEmpty_falseWhenPopulated() {
        let store = makeStore()
        XCTAssertTrue(store.isUnspecifiedChild)

        store.selectedChildIDs = [childA]
        XCTAssertFalse(store.isUnspecifiedChild)
    }

    func test_isUnspecifiedChild_multiSelect_bothRetained() {
        let store = makeStore()
        store.selectedChildIDs = [childA, childB]
        XCTAssertEqual(store.selectedChildIDs, [childA, childB])
        XCTAssertFalse(store.isUnspecifiedChild)
    }

    func test_isUnspecifiedChild_emptyingSelection_returnsToUnspecified() {
        let store = makeStore()
        store.selectedChildIDs = [childA, childB]

        store.selectedChildIDs = []

        XCTAssertTrue(store.isUnspecifiedChild)
    }
}

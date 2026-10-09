import Foundation
import XCTest
@testable import LittleSprout

/// LS-380：03 sheet 的送出狀態機（`FoodRecordEditorStore`）。
///
/// 鎖住的行為（票文 R1 競態維度＋Notes `m18MTy` 資料規則）：
/// - 連點儲存只送一次 upsert；失敗→`.failure`、內容保留；重送時手機照片不重傳。
/// - note trim、空字串送 nil；反應再點一次取消。
/// - 03b：沒碰照片欄＝保留原 `media_id`（縮圖讀不到也不默默拿掉）；「不用照片」＝送 nil。
@MainActor
final class FoodRecordEditorStoreTests: XCTestCase {
    private final class RecordingClient: FoodAPIClient, @unchecked Sendable {
        var upserts: [FoodRecordUpsert] = []
        var uploads = 0
        var uploadedMediaIDs: [UUID] = []
        var softDeleted: [[UUID]] = []
        var onSoftDelete: (() -> Void)?
        var deletes: [UUID] = []
        var upsertError: Error?
        /// 非 nil 時 upsert 會卡住直到 `resume()`——模擬 RPC 在途中。
        var gate: CheckedContinuation<Void, Never>?
        var holdsUpsert = false

        func listFoodCatalog() async throws -> [FoodCatalogItem] { [] }
        func listChildFoodRecords(childID: UUID) async throws -> [ChildFoodRecord] { [] }

        func upsertChildFoodRecord(_ input: FoodRecordUpsert) async throws -> ChildFoodRecord {
            upserts.append(input)
            if holdsUpsert { await withCheckedContinuation { gate = $0 } }
            if let upsertError { throw upsertError }
            return ChildFoodRecord(
                id: UUID(), familyID: UUID(), childID: input.childID, foodID: input.foodID, authorID: nil,
                firstTriedOn: input.firstTriedOn, mediaID: input.mediaID, note: input.note,
                reaction: input.reaction?.rawValue, createdAt: Date(), updatedAt: Date()
            )
        }

        func deleteChildFoodRecord(id: UUID) async throws { deletes.append(id) }
        func listFamilyPhotos(childID: UUID) async throws -> [FamilyPhoto] { [] }
        func fetchFamilyPhoto(id: UUID) async throws -> FamilyPhoto? { nil }
        func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] { [:] }

        func uploadPhoto(childID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
            uploads += 1
            let mediaID = UUID()
            uploadedMediaIDs.append(mediaID)
            return mediaID
        }

        func softDeleteMedia(mediaIDs: [UUID]) async throws {
            softDeleted.append(mediaIDs)
            onSoftDelete?()
        }
    }

    private let taro = FoodCatalogItem(
        id: "taro", nameZh: "芋頭", category: .grainRoot, sortOrder: 10, allergens: [], minAgeMonths: nil
    )

    private func existingRecord(mediaID: UUID?) -> ChildFoodRecord {
        let date = BirthdayFormat.date(fromWireString: "2026-06-08")!
        return ChildFoodRecord(
            id: UUID(), familyID: UUID(), childID: UUID(), foodID: "taro", authorID: nil, firstTriedOn: date,
            mediaID: mediaID, note: "自己抓著吃", reaction: "liked", createdAt: date, updatedAt: date
        )
    }

    func test_save_trimsNote_emptyNoteIsNil_sendsReactionAndDate() async {
        let client = RecordingClient()
        let childID = UUID()
        let store = FoodRecordEditorStore(childID: childID, item: taro, apiClient: client)
        store.note = "   \n "
        store.toggleReaction(.neutral)

        let saved = await store.save()

        XCTAssertNotNil(saved)
        XCTAssertEqual(client.upserts.count, 1)
        XCTAssertNil(client.upserts[0].note, "trimmed.isEmpty → nil（Notes m18MTy）")
        XCTAssertEqual(client.upserts[0].reaction, .neutral)
        XCTAssertEqual(client.upserts[0].childID, childID)
        XCTAssertEqual(client.upserts[0].foodID, "taro")
        XCTAssertEqual(store.saveState, .idle)
    }

    func test_toggleReaction_secondTapClears() {
        let store = FoodRecordEditorStore(childID: UUID(), item: taro, apiClient: RecordingClient())
        store.toggleReaction(.liked)
        XCTAssertEqual(store.reaction, .liked)
        store.toggleReaction(.liked)
        XCTAssertNil(store.reaction, "已選再點一次取消")
    }

    func test_note_isClampedTo2000Characters() {
        let store = FoodRecordEditorStore(childID: UUID(), item: taro, apiClient: RecordingClient())
        store.note = String(repeating: "吃", count: 2_050)
        XCTAssertEqual(store.note.count, FoodRecordEditorStore.noteLimit)
    }

    /// 連點：第一次還在途中（submitting），第二次直接回 nil、不發第二個 upsert。
    func test_save_whileSubmitting_doesNotSendSecondUpsert() async {
        let client = RecordingClient()
        client.holdsUpsert = true
        let store = FoodRecordEditorStore(childID: UUID(), item: taro, apiClient: client)

        let first = Task { await store.save() }
        while client.gate == nil { await Task.yield() }
        XCTAssertEqual(store.saveState, .submitting)
        let second = await store.save()

        XCTAssertNil(second, "送出中再按一次不能再送")
        client.gate?.resume()
        let firstResult = await first.value
        XCTAssertNotNil(firstResult)
        XCTAssertEqual(client.upserts.count, 1)
    }

    /// 失敗 → `.failure`、填好的內容都還在；重送時已上傳的手機照片不重傳（同一張只有一個 media）。
    func test_failureKeepsInput_andRetryDoesNotReuploadSamePhonePhoto() async {
        let client = RecordingClient()
        client.upsertError = AppError.network(message: "offline")
        let store = FoodRecordEditorStore(childID: UUID(), item: taro, apiClient: client)
        store.note = "有點黏"
        store.photo = .local(LocalFoodPhoto(
            data: Data([1, 2, 3]), fileExtension: "jpg", pixelSize: PixelSize(width: 10, height: 10), preview: nil
        ))

        let failed = await store.save()
        XCTAssertNil(failed)
        XCTAssertEqual(store.saveState, .failure(.network(message: "offline")))
        XCTAssertEqual(store.note, "有點黏", "03e：填好的內容都還在")

        client.upsertError = nil
        let saved = await store.save()

        XCTAssertNotNil(saved)
        XCTAssertEqual(client.uploads, 1, "重送不重傳同一張照片")
        XCTAssertEqual(client.upserts.map(\.mediaID), [saved?.mediaID, saved?.mediaID])
    }

    // MARK: - LS-430：upsert 失敗後放棄 → 孤兒 media 清理

    private func phonePhoto() -> LocalFoodPhoto {
        LocalFoodPhoto(
            data: Data([1, 2, 3]), fileExtension: "jpg", pixelSize: PixelSize(width: 10, height: 10), preview: nil
        )
    }

    /// 伺服器明確拒絕（確定沒套用）→ 取消時軟刪剛上傳的那張，不留 `deleted_at IS NULL` 的孤兒（C3a）。
    func test_abandonAfterRejectedUpsert_softDeletesTheUploadedMedia() async {
        let client = RecordingClient()
        client.upsertError = AppError.rejected(message: "denied", code: "42501")
        let store = FoodRecordEditorStore(childID: UUID(), item: taro, apiClient: client)
        store.photo = .local(phonePhoto())

        let failed = await store.save()
        XCTAssertNil(failed)
        XCTAssertTrue(client.softDeleted.isEmpty, "失敗當下不軟刪：同一張還要留給「重送不重傳」")

        await store.abandonUnboundUpload()

        XCTAssertEqual(client.softDeleted, [client.uploadedMediaIDs], "放棄時軟刪剛上傳的那一張")
        await store.abandonUnboundUpload()
        XCTAssertEqual(client.softDeleted.count, 1, "不重複軟刪")
    }

    /// 網路中斷／逾時：伺服器可能已提交（照片其實已綁在記錄上）→ 不得軟刪，交給後端每日清理。
    func test_abandonAfterAmbiguousNetworkFailure_doesNotSoftDelete() async {
        let client = RecordingClient()
        client.upsertError = AppError.network(message: "timeout")
        let store = FoodRecordEditorStore(childID: UUID(), item: taro, apiClient: client)
        store.photo = .local(phonePhoto())
        _ = await store.save()

        client.upsertError = AppError.rejected(message: "denied", code: "42501")
        _ = await store.save()
        await store.abandonUnboundUpload()

        XCTAssertTrue(client.softDeleted.isEmpty, "先前有一次模糊失敗＝可能已綁定，之後即使被拒也不軟刪")
    }

    /// 失敗後「換一張」（`photo` 換成別的）→ 前一張孤兒隨即軟刪。
    func test_changingPhotoAfterRejectedUpsert_softDeletesPreviousUpload() async {
        let client = RecordingClient()
        client.upsertError = AppError.rejected(message: "denied", code: "42501")
        let store = FoodRecordEditorStore(childID: UUID(), item: taro, apiClient: client)
        store.photo = .local(phonePhoto())
        _ = await store.save()

        let softDeleted = expectation(description: "軟刪前一張")
        client.onSoftDelete = { softDeleted.fulfill() }
        store.removePhoto()
        await fulfillment(of: [softDeleted], timeout: 2)

        XCTAssertEqual(client.softDeleted, [client.uploadedMediaIDs])
    }

    /// 儲存成功＝照片已綁定到記錄，之後（sheet 關閉）的放棄不得軟刪。
    func test_abandonAfterSuccessfulSave_doesNotSoftDelete() async {
        let client = RecordingClient()
        let store = FoodRecordEditorStore(childID: UUID(), item: taro, apiClient: client)
        store.photo = .local(phonePhoto())
        let saved = await store.save()
        XCTAssertNotNil(saved)

        await store.abandonUnboundUpload()

        XCTAssertTrue(client.softDeleted.isEmpty)
    }

    func test_edit_untouchedPhotoKeepsMediaID_removePhotoSendsNil() async {
        let mediaID = UUID()
        let client = RecordingClient()
        let record = existingRecord(mediaID: mediaID)
        let store = FoodRecordEditorStore(childID: record.childID, item: taro, editingRecord: record, apiClient: client)
        XCTAssertEqual(store.reaction, .liked, "03b 帶入既有反應")
        XCTAssertEqual(store.note, "自己抓著吃")

        _ = await store.save()
        XCTAssertEqual(client.upserts.last?.mediaID, mediaID, "沒碰照片欄（縮圖也還沒讀到）＝保留原照片")

        store.removePhoto()
        _ = await store.save()
        XCTAssertNil(client.upserts.last?.mediaID, "「不用照片」→ media_id = null（Notes COtpI）")
    }

    /// R1 i4：03b 原照片縮圖讀不到 → 照片欄仍是選取態（顯示「原照片讀取失敗」、有「不用照片」），送出保留原
    /// `media_id`；按「不用照片」後畫面回到兩個來源鈕、送出 null——畫面與送出值一致。
    func test_edit_existingPhotoUnavailable_staysSelectedAndCanBeRemoved() async {
        let mediaID = UUID()
        let client = RecordingClient()  // fetchFamilyPhoto 回 nil＝讀不到
        let record = existingRecord(mediaID: mediaID)
        let store = FoodRecordEditorStore(childID: record.childID, item: taro, editingRecord: record, apiClient: client)
        XCTAssertEqual(store.existingPhotoLoad, .loading)

        await store.loadExistingPhoto()

        XCTAssertEqual(store.existingPhotoLoad, .failed)
        XCTAssertTrue(store.keepsUnresolvedExistingPhoto, "讀不到仍顯示成「有照片」（原照片讀取失敗），不是「沒選」")
        _ = await store.save()
        XCTAssertEqual(client.upserts.last?.mediaID, mediaID, "畫面說有照片，送出就保留原 media_id")

        store.removePhoto()
        XCTAssertFalse(store.keepsUnresolvedExistingPhoto, "按「不用照片」後回到兩個來源鈕")
        _ = await store.save()
        XCTAssertNil(client.upserts.last?.mediaID)
    }

    func test_firstRecord_hasNoExistingPhotoState() {
        let store = FoodRecordEditorStore(childID: UUID(), item: taro, apiClient: RecordingClient())
        XCTAssertEqual(store.existingPhotoLoad, .notApplicable)
        XCTAssertFalse(store.keepsUnresolvedExistingPhoto)
    }

    func test_delete_callsRPCWithRecordID() async throws {
        let client = RecordingClient()
        let record = existingRecord(mediaID: nil)
        let store = FoodRecordEditorStore(childID: record.childID, item: taro, editingRecord: record, apiClient: client)

        try await store.delete()

        XCTAssertEqual(client.deletes, [record.id])
    }
}

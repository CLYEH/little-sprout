import Foundation
@testable import LittleSprout
import os
import XCTest

/// `DiaryComposerStore.removeSelected()`／`discardDraft()` 的孤兒清理（LS-212，依 LS-96
/// `d8634a08` R1 m9／R2 n6／R4 補充）：草稿被移出佇列或編輯器整個被取消時，已經上傳成功過的
/// `media` 列要主動軟刪、影片草稿的本機暫存檔要清掉。從 `DiaryComposerStoreTests`／
/// `DiaryComposerStorePublishRetryTests` 分開放：這裡的測試需要先跑一次「upload 成功但
/// `attachMedia` 失敗」的 `publish()` 才能佈置出「已上傳但未 attach」的狀態，跟那兩支檔案各自
/// 的既有分工（純狀態機／送出重試）是不同的關注點。
@MainActor
final class DiaryComposerStoreDraftCleanupTests: XCTestCase {
    private let familyID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

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

    /// `attachMedia` 恆失敗的 `diaryClient`——讓 `publish()` 在照片已經上傳成功之後才失敗，
    /// 佈置出「`uploadedMediaByDraftID` 有記錄，但從未成功 attach」的狀態（同
    /// `DiaryComposerStorePublishRetryTests` 的既有慣例）。
    private func makeAlwaysFailingAttachClient() -> StubDiaryAPIClient {
        let client = StubDiaryAPIClient()
        client.setCreateHandler { _, _, _, _ in UUID() }
        client.setAttachMediaHandler { _, _, _ in throw AppError.network(message: "connection dropped") }
        return client
    }

    // MARK: - removeSelected：已上傳孤兒 media 軟刪

    func test_removeSelected_draftAlreadyUploaded_softDeletesOrphanMedia() async {
        let mediaService = StubMediaUploadService()
        let uploadedMediaID = UUID()
        mediaService.setUploadPhotoHandler { _, _, _, _ in uploadedMediaID }
        let store = makeStore(diaryAPIClient: makeAlwaysFailingAttachClient(), mediaUploadService: mediaService)
        store.body = "內容"
        addPhoto(store)

        let publishResult = await store.publish()
        XCTAssertFalse(publishResult, "測試前置：attachMedia 恆失敗，publish() 應該失敗但照片已經上傳成功")

        store.toggleSelection(store.photos[0].id)
        await store.removeSelected()

        XCTAssertEqual(
            mediaService.softDeleteMediaCalls, [.init(mediaIDs: [uploadedMediaID])],
            "移除已經上傳過的草稿應該主動軟刪對應 media 列，不論它有沒有被 attach"
        )
        XCTAssertTrue(store.photos.isEmpty)
    }

    func test_removeSelected_draftNeverUploaded_doesNotCallSoftDelete() async {
        let mediaService = StubMediaUploadService()
        let store = makeStore(mediaUploadService: mediaService)
        addPhoto(store)

        store.toggleSelection(store.photos[0].id)
        await store.removeSelected()

        XCTAssertTrue(mediaService.softDeleteMediaCalls.isEmpty, "從未上傳過的草稿沒有孤兒 media 可清，不該打這支 API")
    }

    func test_removeSelected_videoDraft_deletesLocalTempFile() async throws {
        let store = makeStore()
        let tempURL = try MediaDraftTempStorage.newFileURL(extension: "mov")
        try Data([0x00, 0x01]).write(to: tempURL)
        store.addVideo(
            fileURL: tempURL, fileExtension: "mov", duration: 12,
            pixelSize: PixelSize(width: 100, height: 100), previewImage: nil
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path), "測試前置：暫存檔應該先真的寫進去")

        store.toggleSelection(store.photos[0].id)
        await store.removeSelected()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempURL.path),
            "移除影片草稿應該清掉本機暫存檔，否則使用者選了又刪會在 tmp 目錄累積孤兒檔"
        )
    }

    // MARK: - discardDraft：整個編輯器被取消

    func test_discardDraft_afterFailedPublish_softDeletesOrphanMediaForRemainingDrafts() async {
        let mediaService = StubMediaUploadService()
        let uploadedMediaID = UUID()
        mediaService.setUploadPhotoHandler { _, _, _, _ in uploadedMediaID }
        let store = makeStore(diaryAPIClient: makeAlwaysFailingAttachClient(), mediaUploadService: mediaService)
        store.body = "內容"
        addPhoto(store)

        let publishResult = await store.publish()
        XCTAssertFalse(publishResult, "測試前置：attachMedia 恆失敗，publish() 應該失敗但照片已經上傳成功")

        await store.discardDraft()

        XCTAssertEqual(
            mediaService.softDeleteMediaCalls, [.init(mediaIDs: [uploadedMediaID])],
            "使用者放棄整個編輯器時，佇列裡已經上傳過的草稿也要主動軟刪，不只是 removeSelected 那條路徑"
        )
    }

    /// mutation 鑑別力關鍵：拿掉 `discardDraft()` 裡 `guard publishState != .success` 這一行，
    /// 這支測試應該轉紅——成功發佈的照片已經合法 attach，不是孤兒，`discardDraft()` 不該把它
    /// 們也軟刪掉。
    func test_discardDraft_afterSuccessfulPublish_doesNotSoftDeleteAttachedMedia() async {
        let mediaService = StubMediaUploadService()
        let store = makeStore(mediaUploadService: mediaService)
        store.body = "內容"
        addPhoto(store)

        let publishResult = await store.publish()
        XCTAssertTrue(publishResult, "測試前置：預設 stub 不會失敗，publish() 應該成功")

        await store.discardDraft()

        XCTAssertTrue(
            mediaService.softDeleteMediaCalls.isEmpty,
            "發佈成功後的照片已經合法 attach，discardDraft() 不該把它們軟刪掉"
        )
    }

    func test_discardDraft_videoDraft_deletesLocalTempFileEvenWithoutUpload() async throws {
        let store = makeStore()
        let tempURL = try MediaDraftTempStorage.newFileURL(extension: "mp4")
        try Data([0x00, 0x01]).write(to: tempURL)
        store.addVideo(
            fileURL: tempURL, fileExtension: "mp4", duration: 12,
            pixelSize: PixelSize(width: 100, height: 100), previewImage: nil
        )

        await store.discardDraft()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempURL.path),
            "使用者從未上傳就整個取消編輯器，影片本機暫存檔也該被清掉"
        )
    }
}

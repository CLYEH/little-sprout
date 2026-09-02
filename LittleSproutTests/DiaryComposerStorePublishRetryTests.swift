import Foundation
@testable import LittleSprout
import os
import XCTest

/// `DiaryComposerStore.publish()` 的重試路徑：失敗後重試不重複建立 diary／不重傳已成功的
/// 照片（merge-review R1 M2）、重試時內容變了要送新版本給 `update_diary_entry`（R2 N1）、
/// 成功之後擋下重複呼叫（R2 n2）。從 `DiaryComposerStorePublishTests` 拆出——那支檔案加完
/// R2 這批測試後超過 SwiftLint `type_body_length` 上限，理由跟 `DiaryComposerStoreTests`／
/// `DiaryComposerStorePublishTests` 之間的拆分一致（見該檔文件註解）。
@MainActor
final class DiaryComposerStorePublishRetryTests: XCTestCase {
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

    // MARK: - 重試不重複建立 diary／不重傳已成功的照片（merge-review R1 M2）

    func test_publish_retryAfterAttachMediaFailure_doesNotRecreateDiaryOrReuploadPhotos() async {
        let diaryClient = StubDiaryAPIClient()
        let mediaService = StubMediaUploadService()
        let newDiaryID = UUID()
        diaryClient.setCreateHandler { _, _, _, _ in newDiaryID }
        // `@Sendable` handler 不能直接捕捉可變的區域 `var`（Swift 6 嚴格並發）——同
        // `test_publish_success_...` 的 `OSAllocatedUnfairLockBox` 理由，這裡改用鎖包住的計數。
        let attachMediaAttempts = OSAllocatedUnfairLock<Int>(initialState: 0)
        diaryClient.setAttachMediaHandler { _, _, _ in
            let attempt = attachMediaAttempts.withLock { state in
                state += 1
                return state
            }
            if attempt == 1 { throw AppError.network(message: "connection dropped") }
        }
        let store = makeStore(diaryAPIClient: diaryClient, mediaUploadService: mediaService)
        store.body = "8 張照片"
        addPhoto(store, tag: "a")
        addPhoto(store, tag: "b")

        let firstResult = await store.publish()
        XCTAssertFalse(firstResult)
        XCTAssertEqual(diaryClient.createCalls.count, 1, "第一次嘗試應該建立 diary")
        XCTAssertEqual(mediaService.uploadPhotoCalls.count, 2, "第一次嘗試應該上傳兩張照片")

        let secondResult = await store.publish()

        XCTAssertTrue(secondResult)
        XCTAssertEqual(
            diaryClient.createCalls.count, 1, "重試不該再呼叫 create_diary_entry，否則時間軸上會出現重複貼文"
        )
        XCTAssertEqual(
            mediaService.uploadPhotoCalls.count, 2, "已經上傳成功的照片重試不該重傳，否則會留下孤兒 media 列"
        )
        XCTAssertEqual(diaryClient.attachMediaCalls.count, 2, "attachMedia 本身失敗了要重新呼叫")
        XCTAssertEqual(diaryClient.attachMediaCalls.last?.diaryID, newDiaryID, "第二次呼叫要用同一篇 diary 的 id")
    }

    /// merge-review R2 N1：失敗後使用者改了內容才重試，第二次呼叫要把新內容送到後端，不能
    /// 沿用建立當下的舊版本——拿掉 `resolveDiaryID` 裡的 `updateDiaryEntry` 呼叫，這個測試
    /// 應該要紅（PR body mutation 清單）。
    func test_publish_retryAfterAttachMediaFailure_withEditedBody_callsUpdateDiaryEntryWithNewContent() async {
        let diaryClient = StubDiaryAPIClient()
        let mediaService = StubMediaUploadService()
        let newDiaryID = UUID()
        diaryClient.setCreateHandler { _, _, _, _ in newDiaryID }
        let attachMediaAttempts = OSAllocatedUnfairLock<Int>(initialState: 0)
        diaryClient.setAttachMediaHandler { _, _, _ in
            let attempt = attachMediaAttempts.withLock { state in
                state += 1
                return state
            }
            if attempt == 1 { throw AppError.network(message: "connection dropped") }
        }
        let store = makeStore(diaryAPIClient: diaryClient, mediaUploadService: mediaService)
        store.body = "第一版內容"
        addPhoto(store)

        let firstResult = await store.publish()
        XCTAssertFalse(firstResult)
        XCTAssertTrue(diaryClient.updateCalls.isEmpty, "第一次嘗試不該呼叫 update（內容跟建立當下相同）")

        store.body = "改過的第二版內容"
        let secondResult = await store.publish()

        XCTAssertTrue(secondResult)
        XCTAssertEqual(diaryClient.updateCalls.count, 1, "重試時內容變了要呼叫 update_diary_entry")
        XCTAssertEqual(diaryClient.updateCalls.first?.diaryID, newDiaryID)
        XCTAssertEqual(diaryClient.updateCalls.first?.body, "改過的第二版內容")
        XCTAssertEqual(diaryClient.createCalls.count, 1, "沿用既有 diary，不重複建立")
    }

    /// 內容沒變的重試不該多打一次 update——跟上一個測試互補，鎖住「只有內容真的變了才打」
    /// 這個判斷，不是每次重試都無條件呼叫。
    func test_publish_retryAfterAttachMediaFailure_withUnchangedBody_doesNotCallUpdateDiaryEntry() async {
        let diaryClient = StubDiaryAPIClient()
        let mediaService = StubMediaUploadService()
        diaryClient.setCreateHandler { _, _, _, _ in UUID() }
        let attachMediaAttempts = OSAllocatedUnfairLock<Int>(initialState: 0)
        diaryClient.setAttachMediaHandler { _, _, _ in
            let attempt = attachMediaAttempts.withLock { state in
                state += 1
                return state
            }
            if attempt == 1 { throw AppError.network(message: "connection dropped") }
        }
        let store = makeStore(diaryAPIClient: diaryClient, mediaUploadService: mediaService)
        store.body = "內容不變"
        addPhoto(store)

        _ = await store.publish()
        _ = await store.publish()

        XCTAssertTrue(diaryClient.updateCalls.isEmpty, "內容沒變的重試不該多打 update_diary_entry")
    }

    func test_publish_retryAfterUploadFailure_onlyReuploadsRemainingPhotos() async {
        let diaryClient = StubDiaryAPIClient()
        let mediaService = StubMediaUploadService()
        let uploadAttempts = OSAllocatedUnfairLock<Int>(initialState: 0)
        let secondPhotoID = UUID()
        mediaService.setUploadPhotoHandler { _, data, _, _ in
            let attempt = uploadAttempts.withLock { state in
                state += 1
                return state
            }
            // 第一張（tag "a"）永遠成功；第二張（tag "b"）第一次失敗、第二次成功。
            if String(data: data, encoding: .utf8) == "b", attempt <= 2 {
                throw AppError.network(message: "dropped mid-upload")
            }
            return secondPhotoID
        }
        let store = makeStore(diaryAPIClient: diaryClient, mediaUploadService: mediaService)
        store.body = "內容"
        addPhoto(store, tag: "a")
        addPhoto(store, tag: "b")

        let firstResult = await store.publish()
        XCTAssertFalse(firstResult)
        let uploadCallsAfterFirstAttempt = mediaService.uploadPhotoCalls.count

        let secondResult = await store.publish()

        XCTAssertTrue(secondResult)
        XCTAssertEqual(
            mediaService.uploadPhotoCalls.count, uploadCallsAfterFirstAttempt + 1,
            "重試只該補傳第一次失敗的那一張，不是把兩張全部重傳"
        )
    }

    // MARK: - 成功之後擋下重複呼叫（merge-review R2 n2，防禦性 guard）

    /// `resolveDiaryID` 的記憶本身沒有 invalidate 條件，`publish()` 自己補一道底線：成功
    /// 之後不該再送出一次（正常呼叫端會在成功後立刻 dismiss，這裡驗的是防禦層本身生效）。
    func test_publish_afterSuccess_isBlocked() async {
        let diaryClient = StubDiaryAPIClient()
        let store = makeStore(diaryAPIClient: diaryClient)
        store.body = "內容"

        let firstResult = await store.publish()
        XCTAssertTrue(firstResult)
        XCTAssertEqual(diaryClient.createCalls.count, 1)

        let secondResult = await store.publish()

        XCTAssertFalse(secondResult, "成功之後不該再送出一次")
        XCTAssertEqual(diaryClient.createCalls.count, 1, "不該再呼叫 create_diary_entry")
    }
}

import Foundation
@testable import LittleSprout
import UIKit
import XCTest

/// LS-304 merge-review R1 M3(c)：`UploadQueueStore.releaseThumbnails(for:)`——批次匯入摘要頁
/// 離開時釋放終局項目（完成／不可重試失敗）的縮圖，見該方法文件註解與 LS-96 池項
/// `a997f824`(2)。用 `seedForPreview` 直接灌進各種狀態的 entry（同
/// `UploadQueueStoreCancelImportTests` 既有慣例），不需要真的跑上傳流程。
@MainActor
final class UploadQueueStoreReleaseThumbnailsTests: XCTestCase {
    private let familyID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    private func makeThumbnail() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private func seed(
        store: UploadQueueStore, thumbnail: UIImage, state: UploadItemState
    ) -> UUID {
        let upload = PendingUpload(
            kind: .photo(data: Data(), fileExtension: "jpg"), thumbnail: thumbnail,
            pixelSize: PixelSize(width: 4, height: 4)
        )
        store.seedForPreview([.init(upload, enqueuedAt: Date(), state: state)])
        return upload.id
    }

    func test_releaseThumbnails_clearsCompletedEntryThumbnail() {
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: StubMediaUploadService())
        let id = seed(store: store, thumbnail: makeThumbnail(), state: .completed)
        XCTAssertNotNil(store.thumbnail(for: id), "前提：種子項目確實帶了縮圖")

        store.releaseThumbnails(for: [id])

        XCTAssertNil(store.thumbnail(for: id), "完成的項目離開摘要頁後縮圖該被釋放")
    }

    func test_releaseThumbnails_clearsNonRetryableFailedEntryThumbnail() {
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: StubMediaUploadService())
        let id = seed(store: store, thumbnail: makeThumbnail(), state: .failed(.quota))

        store.releaseThumbnails(for: [id])

        XCTAssertNil(store.thumbnail(for: id), "不可重試失敗（LS002）也是終局，縮圖該被釋放")
    }

    func test_releaseThumbnails_keepsRetryableFailedEntryThumbnail() {
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: StubMediaUploadService())
        let id = seed(store: store, thumbnail: makeThumbnail(), state: .failed(.network))

        store.releaseThumbnails(for: [id])

        XCTAssertNotNil(store.thumbnail(for: id), "可重試失敗使用者可能還會按「重試失敗項」，縮圖不能先清掉")
    }

    func test_releaseThumbnails_keepsWaitingAndUploadingEntryThumbnails() {
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: StubMediaUploadService())
        let waitingID = seed(store: store, thumbnail: makeThumbnail(), state: .waiting)
        let uploadingID = seed(store: store, thumbnail: makeThumbnail(), state: .uploading(progress: nil))

        store.releaseThumbnails(for: [waitingID, uploadingID])

        XCTAssertNotNil(store.thumbnail(for: waitingID), "還沒到終局，不該被清")
        XCTAssertNotNil(store.thumbnail(for: uploadingID), "還沒到終局，不該被清")
    }

    func test_releaseThumbnails_unknownID_isNoOp() {
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: StubMediaUploadService())
        store.releaseThumbnails(for: [UUID()])
    }
}

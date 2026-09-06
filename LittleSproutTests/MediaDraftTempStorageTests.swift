import Foundation
@testable import LittleSprout
import XCTest

/// `MediaDraftTempStorage`（LS-212）：日記編輯器影片暫存檔的專屬目錄與 App 啟動時的孤兒清理。
/// 每支測試前後都自己清一次目錄，避免測試順序或平行執行時互相踩到同一個
/// `.temporaryDirectory` 路徑（這個目錄是行程層級的單一路徑，不是每個測試各自獨立的暫存區）。
final class MediaDraftTempStorageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MediaDraftTempStorage.purgeStaleFiles()
    }

    override func tearDown() {
        MediaDraftTempStorage.purgeStaleFiles()
        super.tearDown()
    }

    func test_newFileURL_createsDirectoryAndReturnsUniquePaths() throws {
        let first = try MediaDraftTempStorage.newFileURL(extension: "mp4")
        let second = try MediaDraftTempStorage.newFileURL(extension: "mp4")

        XCTAssertNotEqual(first, second, "每次呼叫都該拿到不同的路徑，不能兩支草稿共用同一個檔名")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: MediaDraftTempStorage.directory.path, isDirectory: nil),
            "目錄應該已經建立好，呼叫端才能直接把檔案寫進去"
        )
        XCTAssertEqual(first.pathExtension, "mp4")
    }

    func test_purgeStaleFiles_removesExistingDirectoryAndContents() throws {
        let fileURL = try MediaDraftTempStorage.newFileURL(extension: "mov")
        try Data([0x01, 0x02, 0x03]).write(to: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "測試前置：檔案應該先真的寫進去")

        MediaDraftTempStorage.purgeStaleFiles()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path), "App 啟動時的清理應該清掉上一個行程留下的暫存檔"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: MediaDraftTempStorage.directory.path),
            "目錄本身也該一併移除（下一次 newFileURL 呼叫會重新建立）"
        )
    }

    /// 目錄不存在（全新安裝、或從未寫過任何草稿）時呼叫不該丟錯——`purgeStaleFiles()` 用
    /// `try?` 吞掉這個情況，這裡驗證的是「呼叫本身安全」，不是回傳值（該函式沒有回傳值）。
    func test_purgeStaleFiles_directoryDoesNotExist_isNoOp() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: MediaDraftTempStorage.directory.path))

        MediaDraftTempStorage.purgeStaleFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: MediaDraftTempStorage.directory.path))
    }
}

import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-397（LS-20 背景續傳，路線 (b)）驗收：LS-20 Story 驗收條 ②「上傳 30 張到一半切出 app，
/// 回來續傳完成」與續傳橫幅（LS-142 `16 上傳佇列` `Resume Banner`）。
///
/// 兩條測試對應票文範圍 1 的兩個情境，共用同一條佇列實作：
/// - app 只是進背景、行程還在（`test_backgroundDuringUpload_...`）；
/// - app 被系統回收、重新啟動（`test_relaunch_...`，落盤還原）。
@MainActor
final class UploadQueueStoreResumeTests: XCTestCase {
    private let familyID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private var directories: [URL] = []

    override func tearDown() async throws {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }

    private func makeUpload(tag: String, id: UUID = UUID()) -> PendingUpload {
        PendingUpload(
            id: id, kind: .photo(data: Data(tag.utf8), fileExtension: "jpg"), thumbnail: nil,
            pixelSize: PixelSize(width: 4, height: 3)
        )
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ls397-\(UUID().uuidString)")
        directories.append(url)
        return url
    }

    /// 同 `UploadQueueStoreTests.waitUntil`，逾時直接 `XCTFail`（不是靜默通過）。
    private func waitUntil(
        timeoutSeconds: Double = 3, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() > deadline {
                return XCTFail("等待條件成立逾時", file: file, line: line)
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func completedCount(_ store: UploadQueueStore) -> Int {
        store.rows.filter { $0.state == .completed }.count
    }

    // MARK: - 進背景再回前景（票文範圍 3：mutation＝`appDidBecomeActive()` 拿掉重送邏輯）

    /// 30 張傳到一半（前 15 張已完成、3 張飛行中卡住、12 張等候）進背景，回前景後全部完成、
    /// 橫幅出現。卡住的 3 張第一次呼叫永遠不回（模擬 app 被暫停後請求沒有回應），第二次才成功
    /// ——只有把它們取消並重送才傳得完；每張的 `onUploadSucceeded` 只觸發一次（沒有重複掛載）。
    func test_backgroundDuringUpload_afterForeground_allCompleteAndResumeBannerShows() async {
        let attempts = OSAllocatedUnfairLock(initialState: [String: Int]())
        let mediaService = StubMediaUploadService()
        mediaService.setUploadPhotoHandler { _, data, _, _ in
            let tag = String(bytes: data, encoding: .utf8) ?? ""
            let attempt = attempts.withLock { counts -> Int in
                counts[tag, default: 0] += 1
                return counts[tag] ?? 0
            }
            if (15...17).contains(Int(tag) ?? 0), attempt == 1 {
                try await Task.sleep(for: .seconds(60)) // 被暫停的請求：不回應，直到被取消
            }
            return UUID()
        }
        var succeededIDs: [UUID] = []
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: mediaService, maxConcurrentUploads: 3,
            onUploadSucceeded: { id, _ in succeededIDs.append(id) }
        )
        addTeardownBlock { @MainActor in store.discardPersistedState() }

        store.enqueue((0..<30).map { makeUpload(tag: "\($0)") })
        await waitUntil { self.completedCount(store) == 15 && store.uploadingCount == 3 }
        XCTAssertFalse(store.resumedFromInterruption, "還沒進過背景，不該出現續傳橫幅")

        store.appDidEnterBackground()
        store.appDidBecomeActive()
        await waitUntil { store.remainingCount == 0 }

        XCTAssertEqual(store.remainingCount, 0, "回前景後全部項目都該完成，不該有卡在 uploading／waiting 的")
        XCTAssertEqual(completedCount(store), 30)
        XCTAssertTrue(store.resumedFromInterruption, "有項目被中斷後重送，續傳橫幅要出現")
        XCTAssertEqual(mediaService.uploadPhotoCalls.count, 33, "30 張＋3 張卡住的各重送一次，不多不少")
        XCTAssertEqual(Set(succeededIDs).count, 30, "每張都成功掛鉤")
        XCTAssertEqual(succeededIDs.count, 30, "onUploadSucceeded 每張只能觸發一次（重複觸發＝重複掛進相簿）")
    }

    // MARK: - app 被回收後重啟（落盤還原）

    /// 第一個行程：5 張入列（3 張已完成、2 張卡住；其中一張掛相簿）後被回收（放掉 store 實例、沿用
    /// 同一個落盤目錄）。第二個行程：還原只列回**未完成**的 2 張、重新登記相簿對照、橫幅出現、重送
    /// 後全部完成，並且完成後 payload 檔案與 manifest 項目都清掉（不會下次啟動又重傳）。
    func test_relaunch_restoresOnlyUnfinishedUploads_andResumesThem() async {
        let persistence = UploadQueuePersistence(directory: makeDirectory())
        let albumID = UUID()
        let stuckAlbumUploadID = UUID()

        let hanging = StubMediaUploadService()
        hanging.setUploadPhotoHandler { _, data, _, _ in
            if Int(String(bytes: data, encoding: .utf8) ?? "") ?? 0 >= 3 { try await Task.sleep(for: .seconds(60)) }
            return UUID()
        }
        let firstProcess = UploadQueueStore(
            familyID: familyID, mediaUploadService: hanging, maxConcurrentUploads: 5, persistence: persistence,
            albumIDProvider: { $0 == stuckAlbumUploadID ? albumID : nil }
        )
        firstProcess.enqueue([
            makeUpload(tag: "0"), makeUpload(tag: "1"), makeUpload(tag: "2"),
            makeUpload(tag: "3", id: stuckAlbumUploadID), makeUpload(tag: "4")
        ])
        await waitUntil { self.completedCount(firstProcess) == 3 }
        XCTAssertEqual(persistence.loadRecords().count, 2, "完成的 3 張要從 manifest 移除，只剩 2 張未完成")
        // 模擬行程被回收：飛行中的請求消失。落盤內容不動（取消造成的失敗是可重試失敗，不清 manifest）。
        firstProcess.resume.tasks.values.forEach { $0.cancel() }

        let secondService = StubMediaUploadService()
        var registered: [UUID: UUID] = [:]
        let restarted = UploadQueueStore(
            familyID: familyID, mediaUploadService: secondService, maxConcurrentUploads: 5, persistence: persistence
        )
        restarted.restorePersistedEntries { registered[$0] = $1 }

        XCTAssertEqual(restarted.rows.count, 2, "重啟後只還原未完成的 2 張")
        XCTAssertEqual(registered, [stuckAlbumUploadID: albumID], "相簿對照要重新登記，續傳成功才掛得進相簿")
        XCTAssertTrue(restarted.resumedFromInterruption, "重啟續傳要出現橫幅")
        await waitUntil { restarted.remainingCount == 0 }
        XCTAssertEqual(restarted.remainingCount, 0, "重啟後 2 張都要重送完成")
        XCTAssertEqual(secondService.uploadPhotoCalls.count, 2)
        XCTAssertTrue(persistence.loadRecords().isEmpty, "完成後 manifest 清空，下次啟動不會再重傳")
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: persistence.directory.path)) ?? []
        XCTAssertEqual(leftover.filter { $0 != "manifest.json" }, [], "完成後 payload 檔案也要刪掉")
    }
}

import Foundation
@testable import LittleSprout
import XCTest

/// LS-410（LS-403 iOS 段，`design/littlesprout.pen` Notes `FBoLL`）：上傳佇列的「移除失敗項」兩段式契約——
/// `markRemoved`／`undoRemove`／`markAllFailedRemoved` 標記即把 manifest 紀錄的 `removed` 旗標落盤（LS-423，
/// payload 檔不動、仍可復原；回收重啟後不還原），`commitRemovals()`（sheet onDismiss）才真的移除並清 payload，
/// 且 manifest 只寫一次。標記中的項目不計入失敗計數、不參與任何自動或批次重試。
@MainActor
final class UploadQueueStoreRemoveFailedTests: XCTestCase {
    private let familyID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private var directories: [URL] = []

    override func tearDown() async throws {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }

    // MARK: - helpers

    private func makeUpload(tag: String, id: UUID = UUID()) -> PendingUpload {
        PendingUpload(
            id: id, kind: .photo(data: Data(tag.utf8), fileExtension: "jpg"), thumbnail: nil,
            pixelSize: PixelSize(width: 4, height: 3)
        )
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ls410-\(UUID().uuidString)")
        directories.append(url)
        return url
    }

    private func waitUntil(
        timeoutSeconds: Double = 3, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() > deadline { return XCTFail("等待條件成立逾時", file: file, line: line) }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// 三張可重試失敗（`.network`）＋一張完成，落盤到暫存目錄。回傳 store 與三張失敗項的 id。
    private struct Fixture {
        let store: UploadQueueStore
        let persistence: UploadQueuePersistence
        let failedIDs: [UUID]
        let service: StubMediaUploadService
    }

    private func makeStoreWithThreeRetryableFailures(
        terminated: @escaping @MainActor (UUID) -> Void = { _ in }
    ) async -> Fixture {
        let persistence = UploadQueuePersistence(directory: makeDirectory())
        let service = StubMediaUploadService()
        service.setUploadPhotoHandler { _, data, _, _ in
            if String(bytes: data, encoding: .utf8) == "ok" { return UUID() }
            throw AppError.network(message: "offline")
        }
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: service, maxConcurrentUploads: 5,
            onUploadFailedTerminal: terminated, persistence: persistence
        )
        addTeardownBlock { @MainActor in store.discardPersistedState() }
        let failed = (0..<3).map { makeUpload(tag: "fail\($0)") }
        store.enqueue([makeUpload(tag: "ok")] + failed)
        await waitUntil { store.failedCount == 3 && store.completedCount == 1 }
        return Fixture(store: store, persistence: persistence, failedIDs: failed.map(\.id), service: service)
    }

    private func payloadFiles(_ persistence: UploadQueuePersistence) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: persistence.directory.path)) ?? [])
            .filter { $0 != "manifest.json" }.sorted()
    }

    // MARK: - 標記／復原（寫 manifest 旗標，不動 payload）

    /// `markRemoved` 只對失敗項生效：等候／上傳中／完成一律 no-op（不能放棄還在飛行中或已完成的項目）。
    func test_markRemoved_onlyAffectsFailedEntries() async {
        let service = StubMediaUploadService()
        service.setUploadPhotoHandler { _, data, _, _ in
            switch String(bytes: data, encoding: .utf8) {
            case "done": return UUID()
            case "fail": throw AppError.network(message: "offline")
            default: try await Task.sleep(for: .seconds(60)); return UUID()
            }
        }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: service, maxConcurrentUploads: 3)
        addTeardownBlock { @MainActor in store.discardPersistedState() }
        let hanging = (0..<3).map { makeUpload(tag: "hang\($0)") } // 佔滿 3 個名額
        let waiting = makeUpload(tag: "wait") // 名額滿：留在 .waiting
        let done = makeUpload(tag: "done")
        let fail = makeUpload(tag: "fail")
        store.enqueue([done, fail] + hanging + [waiting])
        await waitUntil { store.completedCount == 1 && store.failedCount == 1 && store.uploadingCount == 3 }

        ([done.id, waiting.id] + hanging.map(\.id)).forEach { store.markRemoved($0) }
        XCTAssertTrue(store.pendingRemovals.isEmpty, "完成／等候／上傳中不能被標記移除")
        store.markRemoved(UUID()) // 不存在的 id 也不能留下標記
        XCTAssertTrue(store.pendingRemovals.isEmpty)
        store.markRemoved(fail.id)
        XCTAssertEqual(store.pendingRemovals, [fail.id])
    }

    /// 標記中的項目不計入 `failedCount`／`retryableFailedCount`／`remainingCount`，但仍留在 `rows`／`sections`
    /// （墓碑列）；`undoRemove` 之後全部還原。
    func test_marked_leaveCounts_butStayInSections_andUndoRestores() async {
        let fixture = await makeStoreWithThreeRetryableFailures()
        let (store, failedIDs) = (fixture.store, fixture.failedIDs)
        XCTAssertEqual(store.failedCount, 3)
        XCTAssertEqual(store.retryableFailedCount, 3)
        XCTAssertEqual(store.remainingCount, 3)

        store.markRemoved(failedIDs[0])
        XCTAssertEqual(store.failedCount, 2, "標記中的不計入 failedCount")
        XCTAssertEqual(store.retryableFailedCount, 2)
        XCTAssertEqual(store.remainingCount, 2, "放棄的照片不算「還沒完成」")
        XCTAssertEqual(store.completedCount, 1, "標記不會讓完成數變動")
        XCTAssertEqual(store.rows.count, 4, "墓碑列仍在 rows")
        let failedRows = store.sections.first { $0.kind == .failed }?.rows.map(\.id) ?? []
        XCTAssertTrue(failedRows.contains(failedIDs[0]), "墓碑列仍在失敗群，原地換態不搬動")

        store.undoRemove(failedIDs[0])
        XCTAssertEqual(store.failedCount, 3)
        XCTAssertEqual(store.retryableFailedCount, 3)
        XCTAssertEqual(store.remainingCount, 3)
        XCTAssertTrue(store.pendingRemovals.isEmpty)
    }

    func test_markAllFailedRemoved_marksEveryFailedEntryOnly() async {
        let fixture = await makeStoreWithThreeRetryableFailures()
        let (store, failedIDs) = (fixture.store, fixture.failedIDs)
        store.markAllFailedRemoved()
        XCTAssertEqual(store.pendingRemovals, Set(failedIDs), "只標記三張失敗項，完成那張不動")
        XCTAssertEqual(store.failedCount, 0)
        XCTAssertEqual(store.completedCount, 1)
    }

    // MARK: - 重試排除

    /// 「重試這 N 張」（`retryAllRetryable`）與單列重試都不動標記中的項目。
    func test_marked_areSkippedByRetryAllAndSingleRetry() async {
        let fixture = await makeStoreWithThreeRetryableFailures()
        let (store, failedIDs, service) = (fixture.store, fixture.failedIDs, fixture.service)
        let callsBefore = service.uploadPhotoCalls.count
        store.markRemoved(failedIDs[0])

        store.retry(failedIDs[0])
        store.retryAllRetryable()
        await waitUntil { store.failedCount == 2 && store.uploadingCount == 0 && store.waitingCount == 0 }

        XCTAssertEqual(
            service.uploadPhotoCalls.count, callsBefore + 2,
            "只重送另外兩張未標記的；標記中的那張不能被 retry／retryAllRetryable 重送"
        )
        XCTAssertEqual(store.rows.first { $0.id == failedIDs[0] }?.state, .failed(.network))
    }

    /// 回前景自動重試（LS-397）排除標記項：進背景時飛行中、回前景時已被系統中斷成 `.failed(.network)` 的兩張，
    /// 標記的那張維持失敗，沒標記的那張照常翻回等候重送。
    func test_marked_areSkippedByForegroundAutoRetry() async {
        let service = StubMediaUploadService()
        service.setUploadPhotoHandler { _, _, _, _ in
            try await Task.sleep(for: .seconds(60))
            return UUID()
        }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: service, maxConcurrentUploads: 2)
        addTeardownBlock { @MainActor in store.discardPersistedState() }
        let marked = makeUpload(tag: "marked")
        let unmarked = makeUpload(tag: "unmarked")
        store.enqueue([marked, unmarked])
        await waitUntil { store.uploadingCount == 2 }

        store.appDidEnterBackground()
        store.finish(marked.id, state: .failed(.network)) // 背景中被系統中斷（-1005）
        store.finish(unmarked.id, state: .failed(.network))
        store.markRemoved(marked.id)
        store.appDidBecomeActive()

        XCTAssertEqual(
            store.rows.first { $0.id == marked.id }?.state, .failed(.network),
            "標記移除的項目不能被回前景自動重試翻回等候"
        )
        XCTAssertNotEqual(
            store.rows.first { $0.id == unmarked.id }?.state, .failed(.network),
            "對照：沒標記的那張照常被自動重試（否則這條測試量不到排除）"
        )
    }

    // MARK: - commit：真的移除、落盤一次

    /// 標記階段只改 manifest 的 `removed` 旗標（LS-423，payload 檔不動）；`commitRemovals` 一次移除標記的兩張、manifest 只寫一次、
    /// 刪對應 payload 檔，沒標記的那張與完成的那張不受影響，`onUploadFailedTerminal` 對移除的每張各呼叫一次。
    func test_commitRemovals_removesMarkedOnly_writesManifestOnce_deletesPayloads() async {
        var terminated: [UUID] = []
        let fixture = await makeStoreWithThreeRetryableFailures { terminated.append($0) }
        let (store, persistence, failedIDs) = (fixture.store, fixture.persistence, fixture.failedIDs)
        XCTAssertEqual(persistence.loadRecords().count, 3, "三張可重試失敗都還在 manifest（完成的已移出）")
        XCTAssertEqual(payloadFiles(persistence).count, 3)

        store.markRemoved(failedIDs[0])
        store.markRemoved(failedIDs[1])
        XCTAssertEqual(persistence.loadRecords().count, 3, "標記不移除紀錄，只加旗標")
        XCTAssertEqual(payloadFiles(persistence).count, 3, "sheet 還開著、可復原：payload 檔不動")
        let writesBeforeCommit = store.resume.manifestWriteCount

        let removed = store.commitRemovals()

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(store.resume.manifestWriteCount, writesBeforeCommit + 1, "批次提交 manifest 只寫一次（不是每筆一次）")
        XCTAssertEqual(persistence.loadRecords().map(\.id), [failedIDs[2]], "manifest 只剩沒標記的那張")
        XCTAssertEqual(payloadFiles(persistence), ["\(failedIDs[2].uuidString).jpg"], "標記兩張的 payload 檔要刪掉")
        XCTAssertEqual(store.rows.count, 2, "沒標記的失敗項＋完成的那張")
        XCTAssertNil(store.entries[failedIDs[0]])
        XCTAssertNil(store.entries[failedIDs[1]])
        XCTAssertFalse(store.order.contains(failedIDs[0]))
        XCTAssertTrue(store.pendingRemovals.isEmpty, "提交後標記清空")
        XCTAssertEqual(Set(terminated), [failedIDs[0], failedIDs[1]], "解除相簿登記／寶貝標記簿記（同取消匯入）")
        XCTAssertEqual(terminated.count, 2)
    }

    /// 復原的項目留在佇列與落盤：`undoRemove` 之後 `commitRemovals` 什麼都不做（回傳 0、manifest 不寫）。
    func test_commitRemovals_afterUndo_keepsEverything_andWritesNothing() async {
        let fixture = await makeStoreWithThreeRetryableFailures()
        let (store, persistence, failedIDs) = (fixture.store, fixture.persistence, fixture.failedIDs)

        store.markRemoved(failedIDs[0])
        store.undoRemove(failedIDs[0])
        let writesBeforeCommit = store.resume.manifestWriteCount

        XCTAssertEqual(store.commitRemovals(), 0)
        XCTAssertEqual(store.resume.manifestWriteCount, writesBeforeCommit, "沒有標記就不該寫 manifest")
        XCTAssertTrue(persistence.loadRecords().allSatisfy { !$0.removed }, "復原要把旗標寫回 false")
        XCTAssertEqual(persistence.loadRecords().count, 3)
        XCTAssertEqual(store.failedCount, 3)
    }

    /// 全部標記後提交：三張都移除、manifest 清空、`failedCount`／`remainingCount` 歸零、完成數保留（入口列據此隱藏）。
    func test_commitRemovals_allMarked_emptiesQueueOfFailures() async {
        let fixture = await makeStoreWithThreeRetryableFailures()
        let (store, persistence) = (fixture.store, fixture.persistence)
        store.markAllFailedRemoved()
        XCTAssertEqual(store.commitRemovals(), 3)
        XCTAssertTrue(persistence.loadRecords().isEmpty)
        XCTAssertTrue(payloadFiles(persistence).isEmpty)
        XCTAssertEqual(store.remainingCount, 0)
        XCTAssertEqual(store.failedCount, 0)
        XCTAssertEqual(store.completedCount, 1, "完成的照片不受影響（K 跨批次累加）")
    }

    /// 失敗的影片：提交時清掉暫存匯出檔（沿 `cleanupVideoTempFiles`）。
    func test_commitRemovals_failedVideo_removesTempFile() {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        FileManager.default.createFile(atPath: tempFile.path, contents: Data("fake video".utf8))
        defer { try? FileManager.default.removeItem(at: tempFile) }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: StubMediaUploadService())
        let video = PendingUpload(
            kind: .video(fileURL: tempFile, fileExtension: "mov"), thumbnail: nil,
            pixelSize: PixelSize(width: 4, height: 3)
        )
        store.seedForPreview([.init(video, enqueuedAt: Date(), state: .failed(.network))])

        store.markRemoved(video.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path), "標記階段不刪暫存檔（還可以復原）")
        store.commitRemovals()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path), "提交後暫存匯出檔要清掉")
        XCTAssertTrue(store.rows.isEmpty)
    }

    /// 已標記的失敗項若同時被「取消匯入」移除，不能留下指向不存在 entry 的標記。
    func test_cancelPendingImportItems_dropsStaleMark() {
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: StubMediaUploadService())
        let upload = makeUpload(tag: "x")
        store.seedForPreview([.init(upload, enqueuedAt: Date(), state: .failed(.network))])
        store.markRemoved(upload.id)

        store.cancelPendingImportItems([upload.id])

        XCTAssertTrue(store.pendingRemovals.isEmpty)
    }

    // MARK: - LS-423：標記落盤，回收後重啟尊重標記

    /// 標記移除一筆可重試失敗項後 app 被回收（用同一份 manifest 重建 store）：該項不能被還原成 `.waiting` 並自動重傳，
    /// 否則使用者放棄的照片會在下次啟動悄悄傳進相簿；其餘沒標記的失敗項照舊還原重送，被標記項的 payload 檔隨之清掉。
    func test_relaunchAfterMarkingRemoved_doesNotRestoreOrReuploadMarkedEntry() async {
        let fixture = await makeStoreWithThreeRetryableFailures()
        let marked = fixture.failedIDs[0]
        fixture.store.markRemoved(marked)

        let relaunchService = StubMediaUploadService()
        relaunchService.setUploadPhotoHandler { _, _, _, _ in throw AppError.network(message: "offline") }
        let restarted = UploadQueueStore(
            familyID: familyID, mediaUploadService: relaunchService, persistence: fixture.persistence
        )
        restarted.restorePersistedEntries { _ in }
        await waitUntil { relaunchService.uploadPhotoCalls.count >= 2 }
        try? await Task.sleep(nanoseconds: 100_000_000) // 給多餘的第三次上傳（標記項被誤還原）機會冒出來

        XCTAssertNil(restarted.entries[marked], "已標記移除的項目不能被還原進佇列")
        XCTAssertEqual(restarted.rows.count, 2, "只還原沒標記的兩張")
        XCTAssertEqual(relaunchService.uploadPhotoCalls.count, 2, "標記項不可被排程上傳（只剩兩張沒標記的）")
        let expectedFiles = fixture.failedIDs.dropFirst().map { "\($0.uuidString).jpg" }.sorted()
        XCTAssertEqual(payloadFiles(fixture.persistence), expectedFiles, "標記項的 payload 檔要在還原時清掉")
    }

    /// 舊版 manifest（LS-423 之前寫的）沒有 `removed` 這個 key：解碼為 false（照舊還原重送），不能整份解碼失敗而丟掉佇列。
    func test_legacyManifestWithoutRemovedKey_decodesAsNotRemoved() throws {
        let persistence = UploadQueuePersistence(directory: makeDirectory())
        try FileManager.default.createDirectory(at: persistence.directory, withIntermediateDirectories: true)
        let legacy = """
        [{"id":"55555555-5555-5555-5555-555555555555","kind":"photo","fileExtension":"jpg",\
        "payloadFileName":"55555555-5555-5555-5555-555555555555.jpg","pixelWidth":4,"pixelHeight":3,\
        "enqueuedAt":0}]
        """
        try Data(legacy.utf8).write(to: persistence.directory.appendingPathComponent("manifest.json"))

        let records = persistence.loadRecords()

        XCTAssertEqual(records.count, 1, "舊格式 manifest 要能解碼")
        XCTAssertEqual(records.first?.removed, false, "沒有 removed key 視為 false")
    }
}

// LS-423 R2：獨立 extension（主類別 body 已逼近 SwiftLint `type_body_length` 250 行上限）。
extension UploadQueueStoreRemoveFailedTests {
    /// 「移除這 N 張」批次入口（`markAllFailedRemoved`）也要落盤：標記全部後回收重啟，三張都不還原、不排程上傳。
    /// 守住批次路徑的寫盤——最常用的入口若漏寫，使用者放棄的照片會在下次啟動自動傳進相簿。
    func test_relaunchAfterMarkAllFailedRemoved_doesNotRestoreAnyMarkedEntry() async {
        let fixture = await makeStoreWithThreeRetryableFailures()
        fixture.store.markAllFailedRemoved()

        let relaunchService = StubMediaUploadService()
        relaunchService.setUploadPhotoHandler { _, _, _, _ in throw AppError.network(message: "offline") }
        let restarted = UploadQueueStore(
            familyID: familyID, mediaUploadService: relaunchService, persistence: fixture.persistence
        )
        restarted.restorePersistedEntries { _ in }
        try? await Task.sleep(nanoseconds: 100_000_000) // 給被誤還原的項目機會排程上傳

        XCTAssertTrue(restarted.rows.isEmpty, "批次標記的三張都不能被還原進佇列")
        XCTAssertEqual(relaunchService.uploadPhotoCalls.count, 0, "標記項不可被排程上傳")
        XCTAssertTrue(payloadFiles(fixture.persistence).isEmpty, "批次標記項的 payload 檔要在還原時清掉")
    }
}

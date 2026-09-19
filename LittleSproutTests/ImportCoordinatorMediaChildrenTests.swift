import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-319（LS-249 4/4）：`AlbumImportUploadCoordinator` 對
/// `AlbumsStore.mediaChildrenMarker` 的接線——群的 `babyIDs` 非空時，真的走完
/// `startImport(plan:)` → 上傳成功 → 標記 RPC 這條完整路徑；`MediaChildrenMarkingTrackerTests`
/// 已經直接對追蹤器驗證過內部邏輯，這裡只驗證 coordinator 真的有呼叫到那三支登記方法
/// （`beginGroup`／`registerEntry`／`finishRegisteringGroup`），不重複驗證追蹤器本身的行為。
/// helper（`waitUntil`／`fakeLoader`／`group`）拆檔理由同 `AlbumImportCoordinatorStreamingTests`
/// 檔頭。
@MainActor
final class ImportCoordinatorMediaChildrenTests: XCTestCase {
    private let familyID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    private func waitUntil(
        timeoutSeconds: Double = 1, file: StaticString = #filePath, line: UInt = #line,
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

    private func fakeLoader(
        recordedCalls: OSAllocatedUnfairLock<[String]>
    ) -> @Sendable (String) async -> [PendingUpload] {
        { identifier in
            recordedCalls.withLock { $0.append(identifier) }
            return [
                PendingUpload(
                    kind: .photo(data: Data(identifier.utf8), fileExtension: "jpg"), thumbnail: nil,
                    pixelSize: PixelSize(width: 4, height: 3)
                )
            ]
        }
    }

    private func group(
        id: String, identifiers: [String], babyIDs: [UUID] = [], albumID: UUID? = nil
    ) -> ImportPlan.Group {
        ImportPlan.Group(
            id: id, anchorDate: Date(), isDateUnknown: false, assetLocalIdentifiers: identifiers, babyIDs: babyIDs,
            albumID: albumID
        )
    }

    /// 票文範圍 1：群指定了 `babyIDs`，上傳全部成功後要呼叫一次
    /// `set_media_children_batch`，帶正確的 media 數與 babyIDs。
    func test_startImport_groupWithBabyIDs_marksAllUploadedMediaAfterUploadSucceeds() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [String]())
        let babyID = UUID()
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUpload: fakeLoader(recordedCalls: recordedCalls)
        )
        let plan = ImportPlan(groups: [group(id: "g1", identifiers: ["a", "b"], babyIDs: [babyID])])

        let session = coordinator.startImport(plan: plan)

        await waitUntil { session.isFullyEnqueued }
        await waitUntil { apiStub.setMediaChildrenBatchCalls.count == 1 }
        let call = apiStub.setMediaChildrenBatchCalls[0]
        XCTAssertEqual(call.items.count, 2, "兩筆都上傳成功，標記要涵蓋兩筆")
        XCTAssertTrue(call.items.allSatisfy { $0.childIDs == [babyID] })
    }

    /// 票文範圍 1：「babyIDs 為空的群不呼叫」——群沒有指定寶貝時，即使上傳全部成功，也不該
    /// 有任何 `set_media_children_batch` 呼叫。
    func test_startImport_groupWithoutBabyIDs_neverCallsSetMediaChildrenBatch() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [String]())
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUpload: fakeLoader(recordedCalls: recordedCalls)
        )
        let plan = ImportPlan(groups: [group(id: "g1", identifiers: ["a", "b"])])

        let session = coordinator.startImport(plan: plan)

        await waitUntil { session.isFullyEnqueued }
        // 給上傳一點時間真的完成（stub handler 立刻成功）——確認「不呼叫」不是因為還沒跑到。
        await waitUntil { mediaService.uploadPhotoCalls.count == 2 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(apiStub.setMediaChildrenBatchCalls.isEmpty, "沒有指定寶貝的群不該呼叫標記 RPC")
    }

    /// 兩群各自指定不同寶貝——各自獨立標記，不會混在一起（`GroupKey` 用 `UUID` 而非
    /// `ImportPlan.Group.id`，見 `MediaChildrenMarkingTracker` 檔頭文件註解）。
    func test_startImport_twoGroupsWithDifferentBabyIDs_markSeparately() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [String]())
        let babyA = UUID()
        let babyB = UUID()
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUpload: fakeLoader(recordedCalls: recordedCalls)
        )
        let plan = ImportPlan(groups: [
            group(id: "g1", identifiers: ["a"], babyIDs: [babyA]),
            group(id: "g2", identifiers: ["b"], babyIDs: [babyB])
        ])

        let session = coordinator.startImport(plan: plan)

        await waitUntil { session.isFullyEnqueued }
        await waitUntil { apiStub.setMediaChildrenBatchCalls.count == 2 }
        let sentBabyIDSets = Set(apiStub.setMediaChildrenBatchCalls.map { Set($0.items.flatMap(\.childIDs)) })
        XCTAssertEqual(sentBabyIDSets, [[babyA], [babyB]], "兩群各自的 babyIDs 不該混到對方的批次裡")
    }

    // MARK: - merge-review R1 M1（收成正式測試，reviewer 原始 probe 名稱保留供追溯）——可重試
    // 失敗不得永久擋住同群其餘已成功項目的標記；使用者之後重試成功要補送標記。

    /// M1（merge-review R1，實測轉紅→修法後轉綠）：3 張指定同一個寶貝，其中 1 張撞到可重試的
    /// `.network` 失敗——另外 2 張已經上傳成功的仍要標記，不能永遠卡死。修法前這支斷言
    /// `setMediaChildrenBatchCalls.isEmpty`（bug 的症狀）；修法後改斷言「2 張成功的有被標記」
    /// （正確行為）——名稱沿用 reviewer 原始 probe，見票文 R2 派工單。
    func test_probe_retryableUploadFailure_blocksWholeGroupMarking() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [String]())
        let failureCallCount = OSAllocatedUnfairLock(initialState: 0)
        mediaService.setUploadPhotoHandler { _, data, _, _ in
            let identifier = String(bytes: data, encoding: .utf8) ?? ""
            if identifier == "b" {
                failureCallCount.withLock { $0 += 1 }
                throw AppError.network(message: "斷線")
            }
            return UUID()
        }
        let babyID = UUID()
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUpload: fakeLoader(recordedCalls: recordedCalls)
        )
        let plan = ImportPlan(groups: [group(id: "g1", identifiers: ["a", "b", "c"], babyIDs: [babyID])])

        let session = coordinator.startImport(plan: plan)

        await waitUntil { session.isFullyEnqueued }
        await waitUntil { albumsStore.sharedUploadQueueStoreInstance?.retryableFailedCount == 1 }

        await waitUntil(timeoutSeconds: 2) { apiStub.setMediaChildrenBatchCalls.count == 1 }
        guard let call = apiStub.setMediaChildrenBatchCalls.first else {
            return XCTFail("一筆可重試失敗不該擋住另外兩筆已成功的標記——setMediaChildrenBatch 從未被呼叫")
        }
        XCTAssertEqual(call.items.count, 2, "一筆可重試失敗不該擋住另外兩筆已成功的標記")
        XCTAssertTrue(call.items.allSatisfy { $0.childIDs == [babyID] })
    }

    /// M1 延伸：使用者按「重試失敗項」且這次成功——要補送那一筆的標記（獨立呼叫，冪等）。
    func test_probe_retryFailedUploadThenSucceeds_marksWholeGroup() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [String]())
        let failureCallCount = OSAllocatedUnfairLock(initialState: 0)
        mediaService.setUploadPhotoHandler { _, data, _, _ in
            let identifier = String(bytes: data, encoding: .utf8) ?? ""
            if identifier == "b" {
                let isFirstAttempt = failureCallCount.withLock { count -> Bool in
                    let first = count == 0
                    count += 1
                    return first
                }
                if isFirstAttempt { throw AppError.network(message: "斷線") }
            }
            return UUID()
        }
        let babyID = UUID()
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUpload: fakeLoader(recordedCalls: recordedCalls)
        )
        let plan = ImportPlan(groups: [group(id: "g1", identifiers: ["a", "b", "c"], babyIDs: [babyID])])

        let session = coordinator.startImport(plan: plan)

        await waitUntil { session.isFullyEnqueued }
        guard let store = albumsStore.sharedUploadQueueStoreInstance else {
            return XCTFail("sharedUploadQueueStoreInstance 應該已經建立")
        }
        await waitUntil { store.retryableFailedCount == 1 }
        await waitUntil(timeoutSeconds: 2) { apiStub.setMediaChildrenBatchCalls.count == 1 }

        let failedRow = store.rows(in: session.entryIDSet).first { row in
            if case .failed = row.state { return true }
            return false
        }
        guard let failedRow else { return XCTFail("應該有一筆失敗列可重試") }
        store.retry(failedRow.id)

        await waitUntil(timeoutSeconds: 2) { apiStub.setMediaChildrenBatchCalls.count == 2 }
        guard apiStub.setMediaChildrenBatchCalls.count == 2 else {
            return XCTFail("重試成功後應該補送一次獨立的標記 RPC——目前呼叫次數是 \(apiStub.setMediaChildrenBatchCalls.count)")
        }
        let secondCall = apiStub.setMediaChildrenBatchCalls[1]
        XCTAssertEqual(secondCall.items.count, 1, "補交只送這一筆，不重送已經標記過的另外兩筆")
        XCTAssertEqual(secondCall.items[0].childIDs, [babyID])
    }
}

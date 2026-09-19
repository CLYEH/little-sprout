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
}

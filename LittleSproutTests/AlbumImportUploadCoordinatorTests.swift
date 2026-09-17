import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-304：`AlbumImportUploadCoordinator` 的群迭代／展開邏輯——用可注入的 `loadPendingUploads`
/// 掛鉤繞過真實 `PHAsset`（無法在單元測試合成假值，同 Legacy 既有理由），只驗證 coordinator
/// 自己的邏輯（群迭代／略過／`taken_at` 套用／`ImportBatchSession` 累積），不驗證 Photos
/// framework 呼叫本身（那部分——HEIC 轉檔／Live Photo 展開的「asset 層級」判斷——交給
/// `ImportMediaTranscoderTests`（HEIC 純函式）與本檔「一個 identifier 展開成多筆」的測試
/// （模擬 Live Photo 對外可觀察的效果：一個群輸入 N 個 identifier，回來 >N 筆
/// `PendingUpload`，見 `test_startImport_loaderReturnsMoreUploadsThanIdentifiers_*`）。
@MainActor
final class AlbumImportUploadCoordinatorTests: XCTestCase {
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
        uploadsPerIdentifier: @escaping @Sendable (String) -> [PendingUpload] = { identifier in
            [
                PendingUpload(
                    kind: .photo(data: Data(identifier.utf8), fileExtension: "jpg"), thumbnail: nil,
                    pixelSize: PixelSize(width: 4, height: 3)
                )
            ]
        },
        recordedCalls: OSAllocatedUnfairLock<[[String]]>
    ) -> @Sendable ([String]) async -> [PendingUpload] {
        { identifiers in
            recordedCalls.withLock { $0.append(identifiers) }
            return identifiers.flatMap(uploadsPerIdentifier)
        }
    }

    private func group(
        id: String, identifiers: [String], anchorDate: Date = Date(), albumID: UUID? = nil, isSkipped: Bool = false
    ) -> ImportPlan.Group {
        ImportPlan.Group(
            id: id, anchorDate: anchorDate, isDateUnknown: false, assetLocalIdentifiers: identifiers,
            albumID: albumID, isSkipped: isSkipped
        )
    }

    // MARK: - 群迭代／略過群不入列

    func test_startImport_skipsSkippedGroupsAndEmptyGroups() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [[String]]())
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUploads: fakeLoader(recordedCalls: recordedCalls)
        )
        let plan = ImportPlan(groups: [
            group(id: "skipped", identifiers: ["skip-1"], isSkipped: true),
            group(id: "empty", identifiers: []),
            group(id: "valid", identifiers: ["valid-1", "valid-2"])
        ])

        let session = coordinator.startImport(plan: plan)

        await waitUntil { session.isFullyEnqueued }
        XCTAssertEqual(session.nonSkippedGroupCount, 1, "略過群與空群都不計入「共 N 個日期群」")
        let allCalledIdentifiers = recordedCalls.withLock { $0 }.flatMap { $0 }
        XCTAssertEqual(Set(allCalledIdentifiers), ["valid-1", "valid-2"], "只有未略過且非空的群該被讀取")
        XCTAssertEqual(Set(session.entryIDs).count, 2, "兩個 identifier 各自展開成一筆（預設 loader 1:1）")
    }

    // MARK: - taken_at＝群級 anchorDate（票文範圍 1：EXIF 分組日或使用者覆寫）

    func test_startImport_appliesGroupAnchorDateAsTakenAtForEveryUpload() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [[String]]())
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUploads: fakeLoader(recordedCalls: recordedCalls)
        )
        let plan = ImportPlan(groups: [group(id: "g1", identifiers: ["a", "b"], anchorDate: anchor, albumID: UUID())])

        let session = coordinator.startImport(plan: plan)

        await waitUntil { session.isFullyEnqueued }
        // `sharedUploadQueueStore` 的 `enqueue` 觸發 `advance()` 立刻開始上傳（stub 的 handler
        // 預設立刻成功），等 `uploadPhotoCalls` 出現兩筆再斷言。
        await waitUntil { mediaService.uploadPhotoCalls.count == 2 }
        XCTAssertEqual(mediaService.uploadPhotoCalls.map(\.takenAt), [anchor, anchor])
    }

    /// 略過群／沒有相簿的群不該讓 `registerPendingAlbum` 被呼叫；有相簿的群，每一筆（不是
    /// 每一個 identifier）都要各自登記——這裡故意讓 loader 對單一 identifier 回兩筆（模擬
    /// Live Photo 對外可觀察的效果：一個 asset 展開成照片＋短片兩筆佇列項目），驗證登記筆數
    /// 跟著「展開後的筆數」走，不是「identifier 數」。
    func test_startImport_loaderReturnsMoreUploadsThanIdentifiers_registersAndTracksEachExpandedUpload() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let albumID = UUID()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [[String]]())
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUploads: fakeLoader(
                uploadsPerIdentifier: { identifier in
                    [
                        PendingUpload(
                            kind: .photo(data: Data(identifier.utf8), fileExtension: "jpg"), thumbnail: nil,
                            pixelSize: PixelSize(width: 4, height: 3)
                        ),
                        PendingUpload(
                            kind: .video(fileURL: URL(fileURLWithPath: "/tmp/\(identifier).mov"), fileExtension: "mov"),
                            thumbnail: nil, pixelSize: PixelSize(width: 4, height: 3)
                        )
                    ]
                },
                recordedCalls: recordedCalls
            )
        )
        let plan = ImportPlan(groups: [group(id: "g1", identifiers: ["live-1"], albumID: albumID)])

        let session = coordinator.startImport(plan: plan)

        await waitUntil { session.isFullyEnqueued }
        XCTAssertEqual(session.entryIDs.count, 2, "一個 identifier 展開成兩筆，session 都要追蹤到")
        XCTAssertEqual(Set(session.entryIDs).count, 2, "兩筆各自有獨立的 entry id，不是同一筆")
    }

    // MARK: - 略過群沒有相簿也一樣不入列

    func test_startImport_groupWithoutAlbum_stillEnqueues_becauseAlbumIsOptionalNow() async {
        // LS-304：正式版不再要求「每群都指定相簿」（`requiresAlbumSelection` 沒有實作覆寫成
        // `true`，同 C3a「預設不放相簿」）——沒有 albumID 的群一樣會入列，只是不呼叫
        // `registerPendingAlbum`。
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [[String]]())
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUploads: fakeLoader(recordedCalls: recordedCalls)
        )
        let plan = ImportPlan(groups: [group(id: "no-album", identifiers: ["a"], albumID: nil)])

        let session = coordinator.startImport(plan: plan)

        await waitUntil { session.isFullyEnqueued }
        XCTAssertEqual(session.entryIDs.count, 1)
        XCTAssertTrue(albumsStore.pendingUploadAlbumIDs.isEmpty, "沒有相簿的群不該登記任何 entry→albumID")
    }

    func test_requiresAlbumSelection_defaultsFalse() {
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: StubMediaUploadService(),
            albumsStore: AlbumsStore(apiClient: StubAlbumsAPIClient())
        )
        XCTAssertFalse(coordinator.requiresAlbumSelection, "LS-304 正式版不需要 Legacy 過渡期的相簿限制")
    }
}

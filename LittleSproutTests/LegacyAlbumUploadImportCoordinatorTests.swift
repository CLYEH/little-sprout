import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-303 R4（merge-review R3 M1／M2，orchestrator 裁決 `8579e30e`）：
/// `LegacyAlbumUploadImportCoordinator` 的群迭代／略過邏輯與「呼叫端釋放後入列項仍完成」
/// （M2 修法的直接證明）——用可注入的 `loadPendingUploads` 掛鉤繞過真實 `PHAsset`（無法在
/// 單元測試合成假值，同 `PhotosPickerItem` 既有理由），只驗證 coordinator 自己的邏輯與
/// 生命週期，不驗證 Photos framework 呼叫本身。
@MainActor
final class LegacyAlbumUploadImportCoordinatorTests: XCTestCase {
    private let familyID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

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
        recordedCalls: OSAllocatedUnfairLock<[[String]]>
    ) -> @Sendable ([String]) async -> [PendingUpload] {
        { identifiers in
            recordedCalls.withLock { $0.append(identifiers) }
            return identifiers.map { identifier in
                PendingUpload(
                    kind: .photo(data: Data(identifier.utf8), fileExtension: "jpg"), thumbnail: nil,
                    pixelSize: PixelSize(width: 4, height: 3)
                )
            }
        }
    }

    private func group(
        id: String, identifiers: [String], albumID: UUID?, isSkipped: Bool = false
    ) -> ImportPlan.Group {
        ImportPlan.Group(
            id: id, anchorDate: Date(), isDateUnknown: false, assetLocalIdentifiers: identifiers,
            albumID: albumID, isSkipped: isSkipped
        )
    }

    func test_requiresAlbumSelection_isTrue() {
        let coordinator = LegacyAlbumUploadImportCoordinator(
            familyID: familyID, mediaUploadService: StubMediaUploadService(),
            albumsStore: AlbumsStore(apiClient: StubAlbumsAPIClient())
        )
        XCTAssertTrue(coordinator.requiresAlbumSelection)
    }

    /// M2 的直接證明：`startImport` 呼叫後立刻把 coordinator 唯一的強參照釋放（等同使用者
    /// 在讀取位元組期間離開 `AlbumDetailView`、`@State` 被釋放），入列項仍然完成並正確掛進
    /// 相簿——因為 R4 起 store 掛在 `albumsStore`（app 層級），不再依賴 coordinator 存活。
    func test_startImport_coordinatorReleasedImmediately_entryStillCompletesAndAttaches() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let albumID = UUID()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [[String]]())

        var coordinator: LegacyAlbumUploadImportCoordinator? = LegacyAlbumUploadImportCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUploads: fakeLoader(recordedCalls: recordedCalls)
        )
        let plan = ImportPlan(groups: [group(id: "g1", identifiers: ["a", "b"], albumID: albumID)])

        coordinator!.startImport(plan: plan)
        coordinator = nil // 立刻釋放——模擬使用者在讀取飛行中離開畫面

        await waitUntil { apiStub.attachMediaCalls.count == 2 }
        XCTAssertEqual(apiStub.attachMediaCalls.map(\.albumID), [albumID, albumID])
    }

    /// 群迭代：略過的群與沒有 `albumID` 的群都不該被讀取（`loadPendingUploads` 不該被
    /// 對它們的 identifiers 呼叫），只有「未略過且有相簿」的那群真的入列。
    func test_startImport_skipsSkippedGroupsAndGroupsWithoutAlbum() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let validAlbumID = UUID()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [[String]]())

        let coordinator = LegacyAlbumUploadImportCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUploads: fakeLoader(recordedCalls: recordedCalls)
        )
        let plan = ImportPlan(groups: [
            group(id: "skipped", identifiers: ["skip-1"], albumID: validAlbumID, isSkipped: true),
            group(id: "no-album", identifiers: ["no-album-1"], albumID: nil),
            group(id: "valid", identifiers: ["valid-1", "valid-2"], albumID: validAlbumID)
        ])

        coordinator.startImport(plan: plan)

        await waitUntil { apiStub.attachMediaCalls.count == 2 }
        let allCalledIdentifiers = recordedCalls.withLock { $0 }.flatMap { $0 }
        XCTAssertEqual(Set(allCalledIdentifiers), ["valid-1", "valid-2"], "只有未略過且有相簿的群該被讀取")
        XCTAssertEqual(apiStub.attachMediaCalls.map(\.albumID), [validAlbumID, validAlbumID])
    }

    /// 空群（沒有任何 asset）不該產生任何呼叫——同 `ImportPlan.hasUnskippedGroupsWithoutAlbum`
    /// 的「空群不擋主鈕」判斷一致。
    func test_startImport_emptyGroup_producesNoCalls() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [[String]]())

        let coordinator = LegacyAlbumUploadImportCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUploads: fakeLoader(recordedCalls: recordedCalls)
        )
        let plan = ImportPlan(groups: [group(id: "empty", identifiers: [], albumID: UUID())])

        coordinator.startImport(plan: plan)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(recordedCalls.withLock { $0 }.isEmpty)
        XCTAssertTrue(apiStub.attachMediaCalls.isEmpty)
    }
}

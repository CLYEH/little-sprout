import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-304 merge-review R1 M3(a)／M3(b)／m6：`AlbumImportUploadCoordinator` 群內串流入列、
/// 群層級併發上限、影片 kind 的 `taken_at` 覆蓋——拆出獨立檔案，理由同 `AlbumImportUploadCoordinatorTests`
/// 檔頭：主檔逼近 SwiftLint `type_body_length` 上限（同 `TapTargetGateScreenName+Sentinel.swift`
/// 既有拆檔慣例）。helper（`waitUntil`／`fakeLoader`／`group`）與主檔各自一份，非共用抽象
/// （同族兩處各自一份輕量 helper 是這個 codebase 一貫作法，見
/// `AlbumDetailView+Actions.skippedItemsReplyRow` 檔頭「各自完整協定」的既有先例）。
@MainActor
final class AlbumImportCoordinatorStreamingTests: XCTestCase {
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
        uploadsPerIdentifier: @escaping @Sendable (String) async -> [PendingUpload],
        recordedCalls: OSAllocatedUnfairLock<[String]>
    ) -> @Sendable (String) async -> [PendingUpload] {
        { identifier in
            recordedCalls.withLock { $0.append(identifier) }
            return await uploadsPerIdentifier(identifier)
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

    // MARK: - merge-review R1 M3(a)：群內串流入列——不用等整群讀完才入列

    func test_startImport_streamsUploadsPerIdentifier_notWaitingForWholeGroupToFinish() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [String]())
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUpload: fakeLoader(
                uploadsPerIdentifier: { identifier in
                    if identifier == "slow" {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    return [
                        PendingUpload(
                            kind: .photo(data: Data(identifier.utf8), fileExtension: "jpg"), thumbnail: nil,
                            pixelSize: PixelSize(width: 4, height: 3)
                        )
                    ]
                },
                recordedCalls: recordedCalls
            )
        )
        let plan = ImportPlan(groups: [group(id: "g1", identifiers: ["fast", "slow"])])

        let session = coordinator.startImport(plan: plan)

        // 舊的「整群讀完才入列」寫法會在這裡量到 0 筆（要等 500ms 的 slow 也回來才會
        // 一次性 append 兩筆）——串流入列的話 fast 那一筆不用等 slow 就該先出現。
        await waitUntil(timeoutSeconds: 0.3) { session.entryIDs.count == 1 }
        XCTAssertEqual(session.entryIDs.count, 1, "群內串流入列：fast 的那一筆不用等 slow 完成就該先入列")
        XCTAssertFalse(session.isFullyEnqueued, "slow 還沒回來，這一群還沒 resolved")

        await waitUntil(timeoutSeconds: 1) { session.isFullyEnqueued }
        XCTAssertEqual(session.entryIDs.count, 2)
    }

    // MARK: - merge-review R1 M3(b)：群層級併發上限

    func test_startImport_limitsConcurrentGroupLoadsToThree() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [String]())
        let inFlight = OSAllocatedUnfairLock(initialState: 0)
        let maxObserved = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUpload: fakeLoader(
                uploadsPerIdentifier: { identifier in
                    let current = inFlight.withLock { count -> Int in
                        count += 1
                        return count
                    }
                    maxObserved.withLock { $0 = max($0, current) }
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    inFlight.withLock { $0 -= 1 }
                    return [
                        PendingUpload(
                            kind: .photo(data: Data(identifier.utf8), fileExtension: "jpg"), thumbnail: nil,
                            pixelSize: PixelSize(width: 4, height: 3)
                        )
                    ]
                },
                recordedCalls: recordedCalls
            )
        )
        // 每群各自一個 identifier——群層級併發上限在這裡等同 identifier 層級併發上限，直接量得到。
        let groups = (0..<9).map { index in group(id: "g\(index)", identifiers: ["id-\(index)"]) }
        let plan = ImportPlan(groups: groups)

        let session = coordinator.startImport(plan: plan)

        await waitUntil(timeoutSeconds: 3) { session.isFullyEnqueued }
        XCTAssertLessThanOrEqual(maxObserved.withLock { $0 }, 3, "群層級讀取併發不該超過上限（沿用 maxConcurrentUploads=3）")
        XCTAssertGreaterThan(maxObserved.withLock { $0 }, 1, "上限至少要 >1，否則這支測試量不到真正的併發")
    }

    // MARK: - merge-review R2 M4：取消整批後，還沒排到的群不再繼續入列

    /// 5 群、`maxConcurrentGroupLoads=3`——`startImport` 一次只會排滿前 3 群，其餘 2 群排隊
    /// 等其中一群完成才補上（同上面 M3(b) 測試的機制）。用一道 gate 讓已排入的 3 個 loader
    /// 呼叫卡住不回傳，確認「初始一批排滿 3 群、其餘 2 群還沒被讀取」之後才呼叫
    /// `session.cancel()`，再放開 gate 讓那 3 群完成——斷言 `enqueueGroups`／`enqueue` 的
    /// 取消檢查生效：第 4、5 群永遠沒有被 `loadPendingUpload` 呼叫過，`entryIDs`／
    /// `sharedUploadQueueStoreInstance.rows` 都停在 3 筆，不會因為取消之後還繼續讀取而長大。
    func test_startImport_stopsEnqueueingRemainingGroupsAfterCancel() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [String]())
        let gateOpen = OSAllocatedUnfairLock(initialState: false)
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUpload: fakeLoader(
                uploadsPerIdentifier: { identifier in
                    while !gateOpen.withLock({ $0 }) {
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                    return [
                        PendingUpload(
                            kind: .photo(data: Data(identifier.utf8), fileExtension: "jpg"), thumbnail: nil,
                            pixelSize: PixelSize(width: 4, height: 3)
                        )
                    ]
                },
                recordedCalls: recordedCalls
            )
        )
        let groups = (0..<5).map { index in group(id: "g\(index)", identifiers: ["id-\(index)"]) }
        let plan = ImportPlan(groups: groups)

        let session = coordinator.startImport(plan: plan)

        await waitUntil(timeoutSeconds: 1) { recordedCalls.withLock { $0.count } == 3 }
        XCTAssertEqual(recordedCalls.withLock { $0.count }, 3, "初始一批應該排滿 maxConcurrentGroupLoads=3 群")

        session.cancel()
        gateOpen.withLock { $0 = true }

        // 不能只等「entryIDs.count == 3」就斷言——沒有取消檢查時，第 4、5 群在 gate 打開後
        // 一樣幾毫秒內就會完成，`entryIDs.count` 只是短暫經過 3 再繼續長到 5，用
        // `waitUntil` 抓到「曾經是 3」這個瞬間會誤判成通過。固定等待一段遠大於 gate 打開後
        // 排程延遲量級（微秒～個位數毫秒）的時間，確認「不會再長大」而不是「曾經到過 3」。
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(session.entryIDs.count, 3, "取消前已排入的 3 群完成入列，取消後的群零入列")
        XCTAssertEqual(recordedCalls.withLock { $0.count }, 3, "取消後，還沒排到的 2 群不該再被讀取")
        XCTAssertEqual(
            albumsStore.sharedUploadQueueStoreInstance?.rows.count, 3,
            "共用佇列也不該出現取消後才入列的新 id"
        )
    }

    // MARK: - merge-review R1 m6：影片／Live Photo 配對短片的 taken_at 覆蓋

    /// R1 只斷言了 `uploadPhotoCalls` 的 `takenAt`，影片那條路徑零覆蓋（`StubMediaUploadService
    /// .UploadVideoCall` 早就把欄位備好，見該檔 `:26`）——這裡補一個「一個群同時有照片與
    /// Live Photo 配對短片」的樣本，驗證影片 kind 的 entry 也套到同一個群級 `anchorDate`。
    /// 用 `debugTakenAt(_:)` 直接讀 entry（見該方法文件註解），不必真的跑完整條壓縮／上傳
    /// 管線（`AlbumsStore.sharedUploadQueueStore` 沒有開放注入假 `videoPreparer`，讓一支
    /// 指向不存在檔案的假 `fileURL` 真的跑完整條管線只會卡在壓縮失敗，量不到這裡要驗的事）。
    func test_startImport_appliesGroupAnchorDateToVideoUploadsToo() async {
        let apiStub = StubAlbumsAPIClient()
        let albumsStore = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let recordedCalls = OSAllocatedUnfairLock(initialState: [String]())
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = AlbumImportUploadCoordinator(
            familyID: familyID, mediaUploadService: mediaService, albumsStore: albumsStore,
            loadPendingUpload: fakeLoader(
                uploadsPerIdentifier: { identifier in
                    identifier == "live-1" ? [
                        PendingUpload(
                            kind: .photo(data: Data(identifier.utf8), fileExtension: "jpg"), thumbnail: nil,
                            pixelSize: PixelSize(width: 4, height: 3)
                        ),
                        PendingUpload(
                            kind: .video(fileURL: URL(fileURLWithPath: "/tmp/\(identifier).mov"), fileExtension: "mov"),
                            thumbnail: nil, pixelSize: PixelSize(width: 4, height: 3)
                        )
                    ] : []
                },
                recordedCalls: recordedCalls
            )
        )
        let plan = ImportPlan(groups: [group(id: "g1", identifiers: ["live-1"], anchorDate: anchor)])

        let session = coordinator.startImport(plan: plan)

        await waitUntil { session.entryIDs.count == 2 }
        guard let store = albumsStore.sharedUploadQueueStoreInstance else {
            return XCTFail("startImport 之後應該已經建立 sharedUploadQueueStoreInstance")
        }
        let videoID = session.entryIDs[1]
        XCTAssertEqual(store.debugTakenAt(videoID), anchor, "Live Photo 配對短片（video kind）的 takenAt 也要套群級 anchorDate")
    }
}

import Foundation
@testable import LittleSprout
import XCTest

/// 自由函式（不是 `TimelineContentAssemblerTests` 的實例方法）：stub 的 `@Sendable` handler
/// 閉包不能捕捉非 Sendable 的 `self`，見 `TimelineStoreTests.swift` 的 `timelinePointer` 同一個
/// 理由。刻意不標 `private`：`TimelineContentAssemblerThumbPathTests.swift`（LS-130，拆檔
/// 純粹為了 SwiftLint `type_body_length`，見該檔開頭註解）以 extension 共用這兩個工廠函式。
func pointer(kind: FeedKind, refId: UUID, occurredAt: Date = Date()) -> TimelineFeedPointer {
    TimelineFeedPointer(kind: kind, refId: refId, occurredAt: occurredAt, childIds: [])
}

func mediaRow(
    id: UUID, path: String, type: MediaType = .photo,
    thumbPath: String? = nil, thumbWidth: Int? = nil, thumbHeight: Int? = nil
) -> MediaRow {
    MediaRow(
        id: id, storagePath: path, type: type, width: 800, height: 600,
        thumbPath: thumbPath, thumbWidth: thumbWidth, thumbHeight: thumbHeight
    )
}

final class TimelineContentAssemblerTests: XCTestCase {
    private let diaryID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let albumID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private let mediaID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!

    func test_assemble_emptyPointers_returnsEmpty() async throws {
        let stub = StubTimelineAPIClient()
        let entries = try await TimelineContentAssembler.assemble(pointers: [], apiClient: stub)
        XCTAssertTrue(entries.isEmpty)
    }

    func test_assemble_diaryKind_takesFirst3PreviewPhotosAndTotalCount() async throws {
        let stub = StubTimelineAPIClient()
        let mediaIDs = (0..<5).map { _ in UUID() }
        stub.setFetchDiariesHandler { [diaryID] ids in
            XCTAssertEqual(ids, [diaryID])
            return [DiaryRow(id: diaryID, body: "今天...", entryDate: Date(), createdAt: Date())]
        }
        stub.setFetchDiaryMediaLinksHandler { [diaryID] diaryIds in
            XCTAssertEqual(diaryIds, [diaryID])
            // 刻意打亂順序送回，驗證組裝端有依 sort_order 排序，不是依回傳順序。
            return mediaIDs.enumerated().map { index, id in
                DiaryMediaLinkRow(diaryId: diaryID, mediaId: id, sortOrder: mediaIDs.count - index)
            }.shuffled()
        }
        stub.setFetchMediaHandler { ids in
            // merge-review R1 M3：只該查前 3 張（sort_order 最小的 3 個），不是全部 5 張
            // ——這是過取修法的核心斷言，見下方 `test_assemble_diaryKind_onlyFetchesTop3...`
            // 的多篇日記版本。
            XCTAssertEqual(ids.count, 3, "只該查前 3 張附照的 media 列，不是全部")
            return ids.map { mediaRow(id: $0, path: "f/\($0).jpg") }
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let entries = try await TimelineContentAssembler.assemble(
            pointers: [pointer(kind: .diary, refId: diaryID)], apiClient: stub
        )

        XCTAssertEqual(entries.count, 1)
        guard case .diary(let content) = entries[0].content else {
            return XCTFail("預期組出 .diary content")
        }
        XCTAssertEqual(content.previewPhotos.count, 3, "日記卡附照只露 3 張")
        XCTAssertEqual(content.totalPhotoCount, 5, "總數不受只取前 3 張影響——來自連結表列數，不是抓到的 media 列數")
        // sort_order 最小（1）的那個是 mediaIDs 最後一個 element（sortOrder = count - index）。
        XCTAssertEqual(content.previewPhotos[0].id, mediaIDs.last)
    }

    /// merge-review R1 M3 的核心量級斷言：一頁多篇日記、每篇附照遠超過 3 張時，實際查詢／
    /// 簽名的 media id 數量必須被「每篇最多 3 張」夾住，不會隨附照總數線性成長——這是過取
    /// 修法要防的「一頁 20 篇日記、每篇 20 張＝400 個 id 塞進 GET .in() 超過 proxy 長度上限」
    /// 的縮小重現。
    func test_assemble_diaryKind_onlyFetchesTop3PhotosPerDiary_evenWithManyDiariesAndPhotos() async throws {
        let stub = StubTimelineAPIClient()
        let diaryIDs = (0..<3).map { _ in UUID() }
        stub.setFetchDiariesHandler { ids in
            ids.map { DiaryRow(id: $0, body: "x", entryDate: Date(), createdAt: Date()) }
        }
        stub.setFetchDiaryMediaLinksHandler { diaryIds in
            // 每篇日記附 5 張——若沒有夾住上限，media id 總數會是 3×5=15；夾住後應該只有 3×3=9。
            diaryIds.flatMap { diaryId in
                (0..<5).map { index in
                    DiaryMediaLinkRow(diaryId: diaryId, mediaId: UUID(), sortOrder: index)
                }
            }
        }
        stub.setFetchMediaHandler { ids in
            // 斷言寫在 handler 內、不捕捉可變區域變數（handler 是 @Sendable 閉包）。
            XCTAssertEqual(ids.count, 9, "3 篇日記各只該查前 3 張，media id 總數上限 9，不是 15")
            return ids.map { mediaRow(id: $0, path: "f/\($0).jpg") }
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let pointers = diaryIDs.map { pointer(kind: .diary, refId: $0) }
        let entries = try await TimelineContentAssembler.assemble(pointers: pointers, apiClient: stub)

        for entry in entries {
            guard case .diary(let content) = entry.content else { return XCTFail("預期組出 .diary content") }
            XCTAssertEqual(content.previewPhotos.count, 3)
            XCTAssertEqual(content.totalPhotoCount, 5)
        }
    }

    func test_assemble_albumKind_includesCover() async throws {
        let stub = StubTimelineAPIClient()
        let coverID = UUID()
        stub.setFetchAlbumsHandler { [albumID, coverID] ids in
            XCTAssertEqual(ids, [albumID])
            return [AlbumRow(id: albumID, title: "生日派對", coverMediaId: coverID)]
        }
        stub.setFetchMediaHandler { [coverID] ids in
            XCTAssertEqual(ids, [coverID])
            return [mediaRow(id: coverID, path: "f/cover.jpg")]
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let entries = try await TimelineContentAssembler.assemble(
            pointers: [pointer(kind: .album, refId: albumID)], apiClient: stub
        )

        guard case .album(let content) = entries[0].content else {
            return XCTFail("預期組出 .album content")
        }
        XCTAssertEqual(content.title, "生日派對")
        XCTAssertNotNil(content.cover?.signedURL)
    }

    func test_assemble_albumKind_noCover_producesNilCoverWithoutMediaCall() async throws {
        let stub = StubTimelineAPIClient()
        stub.setFetchAlbumsHandler { [albumID] _ in
            [AlbumRow(id: albumID, title: "無封面相簿", coverMediaId: nil)]
        }
        stub.setFetchMediaHandler { _ in
            XCTFail("沒有封面時不該查 media")
            return []
        }

        let entries = try await TimelineContentAssembler.assemble(
            pointers: [pointer(kind: .album, refId: albumID)], apiClient: stub
        )

        guard case .album(let content) = entries[0].content else {
            return XCTFail("預期組出 .album content")
        }
        XCTAssertNil(content.cover)
    }

    func test_assemble_mediaKind_standalonePhoto() async throws {
        let stub = StubTimelineAPIClient()
        stub.setFetchMediaHandler { [mediaID] ids in
            XCTAssertEqual(ids, [mediaID])
            return [mediaRow(id: mediaID, path: "f/solo.jpg")]
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let entries = try await TimelineContentAssembler.assemble(
            pointers: [pointer(kind: .media, refId: mediaID)], apiClient: stub
        )

        guard case .media(let content) = entries[0].content else {
            return XCTFail("預期組出 .media content")
        }
        XCTAssertEqual(content.id, mediaID)
    }

    // LS-130 thumb_path 選路測試（assemble .media kind／fetchDiaryPhotos）已搬到
    // `TimelineContentAssemblerThumbPathTests.swift`（extension，SwiftLint `type_body_length`
    // 拆檔，見該檔開頭註解）。

    func test_assemble_mixedKinds_preservesPointerOrderAndKind() async throws {
        let stub = StubTimelineAPIClient()
        stub.setFetchDiariesHandler { [diaryID] _ in
            [DiaryRow(id: diaryID, body: "x", entryDate: Date(), createdAt: Date())]
        }
        stub.setFetchAlbumsHandler { [albumID] _ in
            [AlbumRow(id: albumID, title: "y", coverMediaId: nil)]
        }
        stub.setFetchMediaHandler { [mediaID] ids in
            ids.contains(mediaID) ? [mediaRow(id: mediaID, path: "f/z.jpg")] : []
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let now = Date()
        let pointers = [
            pointer(kind: .media, refId: mediaID, occurredAt: now),
            pointer(kind: .diary, refId: diaryID, occurredAt: now.addingTimeInterval(-60)),
            pointer(kind: .album, refId: albumID, occurredAt: now.addingTimeInterval(-120))
        ]

        let entries = try await TimelineContentAssembler.assemble(pointers: pointers, apiClient: stub)

        XCTAssertEqual(entries.map(\.kind), [.media, .diary, .album], "組裝後的順序必須跟指標順序一致")
        XCTAssertNotNil(entries[0].content)
        XCTAssertNotNil(entries[1].content)
        XCTAssertNotNil(entries[2].content)
    }

    func test_assemble_batchFailure_propagatesError() async {
        let stub = StubTimelineAPIClient()
        stub.setFetchDiariesHandler { _ in throw AppError.server(message: "boom", code: nil) }

        do {
            _ = try await TimelineContentAssembler.assemble(
                pointers: [pointer(kind: .diary, refId: diaryID)], apiClient: stub
            )
            XCTFail("其中一支批次查詢失敗應該讓整體 assemble 拋錯")
        } catch {
            // 預期會 throw，不斷言確切型別（withThrowingTaskGroup 可能包一層）。
        }
    }

    func test_fetchDiaryPhotos_returnsAllPhotosSortedBySortOrder() async throws {
        let stub = StubTimelineAPIClient()
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        stub.setFetchDiaryMediaLinksHandler { [diaryID] diaryIds in
            XCTAssertEqual(diaryIds, [diaryID])
            return [
                DiaryMediaLinkRow(diaryId: diaryID, mediaId: idB, sortOrder: 1),
                DiaryMediaLinkRow(diaryId: diaryID, mediaId: idA, sortOrder: 0),
                DiaryMediaLinkRow(diaryId: diaryID, mediaId: idC, sortOrder: 2)
            ]
        }
        stub.setFetchMediaHandler { ids in
            ids.map { mediaRow(id: $0, path: "f/\($0).jpg") }
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let photos = try await TimelineContentAssembler.fetchDiaryPhotos(diaryID: diaryID, apiClient: stub)

        XCTAssertEqual(photos.map(\.id), [idA, idB, idC], "全部附照依 sort_order 排序，不只前 3 張")
    }

    // LS-130 瀑布流縮圖選路測試已搬到 `TimelineContentAssemblerThumbPathTests.swift`
    // （extension，SwiftLint `type_body_length` 拆檔，見該檔開頭註解）。
}

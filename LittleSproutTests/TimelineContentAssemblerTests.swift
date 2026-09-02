import Foundation
@testable import LittleSprout
import XCTest

/// 自由函式（不是 `TimelineContentAssemblerTests` 的實例方法）：stub 的 `@Sendable` handler
/// 閉包不能捕捉非 Sendable 的 `self`，見 `TimelineStoreTests.swift` 的 `timelinePointer` 同一個
/// 理由。
private func pointer(kind: FeedKind, refId: UUID, occurredAt: Date = Date()) -> TimelineFeedPointer {
    TimelineFeedPointer(kind: kind, refId: refId, occurredAt: occurredAt, childIds: [])
}

private func mediaRow(id: UUID, path: String) -> MediaRow {
    MediaRow(id: id, storagePath: path, type: .photo, width: 800, height: 600)
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
            ids.map { mediaRow(id: $0, path: "f/\($0).jpg") }
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
        XCTAssertEqual(content.totalPhotoCount, 5, "總數不受只取前 3 張影響")
        // sort_order 最小（1）的那個是 mediaIDs 最後一個 element（sortOrder = count - index）。
        XCTAssertEqual(content.previewPhotos[0].id, mediaIDs.last)
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
}

import Foundation
@testable import LittleSprout
import os

/// `TimelineStore`／`TimelineContentAssembler` 測試用假 `TimelineAPIClient`——不打真網路，
/// 用可設定的 handler 決定各方法的表現（同 `StubChildAPIClient` 的模式，見該檔）。
final class StubTimelineAPIClient: TimelineAPIClient, @unchecked Sendable {
    typealias FetchPointersHandler = @Sendable (UUID, UUID?, TimelineCursor?, Int) async throws -> [TimelineFeedPointer]
    typealias FetchDiariesHandler = @Sendable ([UUID]) async throws -> [DiaryRow]
    typealias FetchDiaryMediaLinksHandler = @Sendable ([UUID]) async throws -> [DiaryMediaLinkRow]
    typealias FetchAlbumsHandler = @Sendable ([UUID]) async throws -> [AlbumRow]
    typealias FetchMediaHandler = @Sendable ([UUID]) async throws -> [MediaRow]
    typealias SignedURLsHandler = @Sendable ([String]) async throws -> [String: URL]

    struct FetchPointersCall: Equatable {
        let familyID: UUID
        let childID: UUID?
        let cursor: TimelineCursor?
        let limit: Int
    }

    private struct Box {
        var fetchPointersHandler: FetchPointersHandler = { _, _, _, _ in [] }
        var fetchPointersCalls: [FetchPointersCall] = []
        var fetchDiariesHandler: FetchDiariesHandler = { _ in [] }
        var fetchDiaryMediaLinksHandler: FetchDiaryMediaLinksHandler = { _ in [] }
        var fetchAlbumsHandler: FetchAlbumsHandler = { _ in [] }
        var fetchMediaHandler: FetchMediaHandler = { _ in [] }
        var signedURLsHandler: SignedURLsHandler = { _ in [:] }
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var fetchPointersCalls: [FetchPointersCall] {
        box.withLock { $0.fetchPointersCalls }
    }

    func setFetchPointersHandler(_ handler: @escaping FetchPointersHandler) {
        box.withLock { $0.fetchPointersHandler = handler }
    }

    func setFetchDiariesHandler(_ handler: @escaping FetchDiariesHandler) {
        box.withLock { $0.fetchDiariesHandler = handler }
    }

    func setFetchDiaryMediaLinksHandler(_ handler: @escaping FetchDiaryMediaLinksHandler) {
        box.withLock { $0.fetchDiaryMediaLinksHandler = handler }
    }

    func setFetchAlbumsHandler(_ handler: @escaping FetchAlbumsHandler) {
        box.withLock { $0.fetchAlbumsHandler = handler }
    }

    func setFetchMediaHandler(_ handler: @escaping FetchMediaHandler) {
        box.withLock { $0.fetchMediaHandler = handler }
    }

    func setSignedURLsHandler(_ handler: @escaping SignedURLsHandler) {
        box.withLock { $0.signedURLsHandler = handler }
    }

    func fetchTimelinePointers(
        familyID: UUID, childID: UUID?, cursor: TimelineCursor?, limit: Int
    ) async throws -> [TimelineFeedPointer] {
        let call = FetchPointersCall(familyID: familyID, childID: childID, cursor: cursor, limit: limit)
        box.withLock { $0.fetchPointersCalls.append(call) }
        let handler = box.withLock { $0.fetchPointersHandler }
        return try await handler(familyID, childID, cursor, limit)
    }

    func fetchDiaries(ids: [UUID]) async throws -> [DiaryRow] {
        let handler = box.withLock { $0.fetchDiariesHandler }
        return try await handler(ids)
    }

    func fetchDiaryMediaLinks(diaryIds: [UUID]) async throws -> [DiaryMediaLinkRow] {
        let handler = box.withLock { $0.fetchDiaryMediaLinksHandler }
        return try await handler(diaryIds)
    }

    func fetchAlbums(ids: [UUID]) async throws -> [AlbumRow] {
        let handler = box.withLock { $0.fetchAlbumsHandler }
        return try await handler(ids)
    }

    func fetchMedia(ids: [UUID]) async throws -> [MediaRow] {
        let handler = box.withLock { $0.fetchMediaHandler }
        return try await handler(ids)
    }

    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] {
        let handler = box.withLock { $0.signedURLsHandler }
        return try await handler(paths)
    }
}

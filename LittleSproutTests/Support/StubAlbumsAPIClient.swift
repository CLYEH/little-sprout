import Foundation
@testable import LittleSprout
import os

/// `AlbumsStore`／`AlbumsContentAssembler` 測試用假 `AlbumsAPIClient`——不打真網路，用可設定
/// 的 handler 決定各方法的表現（同 `StubTimelineAPIClient` 的模式，見該檔）。
final class StubAlbumsAPIClient: AlbumsAPIClient, @unchecked Sendable {
    typealias FetchAlbumsHandler = @Sendable (UUID, AlbumsCursor?, Int) async throws -> [AlbumListingRow]
    typealias FetchAlbumMediaLinksHandler = @Sendable ([UUID]) async throws -> [AlbumMediaLinkRow]
    typealias FetchAlbumChildrenHandler = @Sendable ([UUID]) async throws -> [AlbumChildLinkRow]
    typealias FetchMediaHandler = @Sendable ([UUID]) async throws -> [MediaRow]
    typealias SignedURLsHandler = @Sendable ([String]) async throws -> [String: URL]
    typealias CreateAlbumHandler = @Sendable (UUID, String) async throws -> AlbumListingRow
    typealias SetAlbumChildrenHandler = @Sendable (UUID, [UUID]) async throws -> Void

    struct FetchAlbumsCall: Equatable {
        let familyID: UUID
        let cursor: AlbumsCursor?
        let limit: Int
    }

    struct SetAlbumChildrenCall: Equatable {
        let albumID: UUID
        let childIDs: [UUID]
    }

    private struct Box {
        var fetchAlbumsHandler: FetchAlbumsHandler = { _, _, _ in [] }
        var fetchAlbumsCalls: [FetchAlbumsCall] = []
        var fetchAlbumMediaLinksHandler: FetchAlbumMediaLinksHandler = { _ in [] }
        var fetchAlbumChildrenHandler: FetchAlbumChildrenHandler = { _ in [] }
        var fetchMediaHandler: FetchMediaHandler = { _ in [] }
        var signedURLsHandler: SignedURLsHandler = { _ in [:] }
        var createAlbumHandler: CreateAlbumHandler = { _, title in
            AlbumListingRow(id: UUID(), title: title, coverMediaId: nil, createdAt: Date())
        }
        var setAlbumChildrenHandler: SetAlbumChildrenHandler = { _, _ in }
        var setAlbumChildrenCalls: [SetAlbumChildrenCall] = []
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var fetchAlbumsCalls: [FetchAlbumsCall] {
        box.withLock { $0.fetchAlbumsCalls }
    }

    var setAlbumChildrenCalls: [SetAlbumChildrenCall] {
        box.withLock { $0.setAlbumChildrenCalls }
    }

    func setFetchAlbumsHandler(_ handler: @escaping FetchAlbumsHandler) {
        box.withLock { $0.fetchAlbumsHandler = handler }
    }

    func setFetchAlbumMediaLinksHandler(_ handler: @escaping FetchAlbumMediaLinksHandler) {
        box.withLock { $0.fetchAlbumMediaLinksHandler = handler }
    }

    func setFetchAlbumChildrenHandler(_ handler: @escaping FetchAlbumChildrenHandler) {
        box.withLock { $0.fetchAlbumChildrenHandler = handler }
    }

    func setFetchMediaHandler(_ handler: @escaping FetchMediaHandler) {
        box.withLock { $0.fetchMediaHandler = handler }
    }

    func setSignedURLsHandler(_ handler: @escaping SignedURLsHandler) {
        box.withLock { $0.signedURLsHandler = handler }
    }

    func setCreateAlbumHandler(_ handler: @escaping CreateAlbumHandler) {
        box.withLock { $0.createAlbumHandler = handler }
    }

    func setSetAlbumChildrenHandler(_ handler: @escaping SetAlbumChildrenHandler) {
        box.withLock { $0.setAlbumChildrenHandler = handler }
    }

    func fetchAlbums(familyID: UUID, cursor: AlbumsCursor?, limit: Int) async throws -> [AlbumListingRow] {
        let call = FetchAlbumsCall(familyID: familyID, cursor: cursor, limit: limit)
        box.withLock { $0.fetchAlbumsCalls.append(call) }
        let handler = box.withLock { $0.fetchAlbumsHandler }
        return try await handler(familyID, cursor, limit)
    }

    func fetchAlbumMediaLinks(albumIds: [UUID]) async throws -> [AlbumMediaLinkRow] {
        let handler = box.withLock { $0.fetchAlbumMediaLinksHandler }
        return try await handler(albumIds)
    }

    func fetchAlbumChildren(albumIds: [UUID]) async throws -> [AlbumChildLinkRow] {
        let handler = box.withLock { $0.fetchAlbumChildrenHandler }
        return try await handler(albumIds)
    }

    func fetchMedia(ids: [UUID]) async throws -> [MediaRow] {
        let handler = box.withLock { $0.fetchMediaHandler }
        return try await handler(ids)
    }

    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] {
        let handler = box.withLock { $0.signedURLsHandler }
        return try await handler(paths)
    }

    func createAlbum(familyID: UUID, title: String) async throws -> AlbumListingRow {
        let handler = box.withLock { $0.createAlbumHandler }
        return try await handler(familyID, title)
    }

    func setAlbumChildren(albumID: UUID, childIDs: [UUID]) async throws {
        box.withLock { $0.setAlbumChildrenCalls.append(SetAlbumChildrenCall(albumID: albumID, childIDs: childIDs)) }
        let handler = box.withLock { $0.setAlbumChildrenHandler }
        try await handler(albumID, childIDs)
    }
}

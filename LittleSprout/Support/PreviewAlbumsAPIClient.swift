#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview`／`TapTargetGateHarness` 用的假 `AlbumsAPIClient`——不打真網路
/// （同 `PreviewTimelineAPIClient` 的角色，見該檔）。生產路徑一律用 `SupabaseAlbumsAPIClient`。
private final class PreviewAlbumsAPIClient: AlbumsAPIClient, @unchecked Sendable {
    /// LS-396：可帶清單（同 LS-370 `PreviewChildAPIClient` 先例）——家庭有 seed 時
    /// `AlbumsView.task` 會打 `refresh`，只 `seedForPreview` 會被蓋成空清單。只回第一頁。
    private let albums: [AlbumListingRow]

    init(albums: [AlbumListingRow] = []) {
        self.albums = albums
    }

    func fetchAlbums(familyID: UUID, cursor: AlbumsCursor?, limit: Int) async throws -> [AlbumListingRow] {
        cursor == nil ? albums : []
    }
    func fetchAlbumChildren(albumIds: [UUID]) async throws -> [AlbumChildLinkRow] { [] }
    func fetchMedia(ids: [UUID]) async throws -> [MediaRow] { [] }
    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] { [:] }
    func createAlbum(familyID: UUID, title: String) async throws -> AlbumListingRow {
        AlbumListingRow(id: UUID(), title: title, createdAt: Date())
    }
    func setAlbumChildren(albumID: UUID, childIDs: [UUID]) async throws {}
    func setAlbumDeleted(albumID: UUID, deleted: Bool) async throws {}
    func fetchAlbumMediaLinks(albumID: UUID) async throws -> [AlbumMediaLinkRow] { [] }
    func fetchMaxSortOrder(albumID: UUID) async throws -> Int? { nil }
    func attachMedia(albumID: UUID, familyID: UUID, mediaID: UUID, sortOrder: Int) async throws {}
    func updateAlbumTitle(albumID: UUID, title: String) async throws {}
    func setMediaChildrenBatch(items: [MediaChildrenBatchItem]) async throws {}
}

extension AlbumsStore {
    @MainActor
    static func preview(albums: [AlbumListingRow] = []) -> AlbumsStore {
        AlbumsStore(apiClient: PreviewAlbumsAPIClient(albums: albums))
    }
}
#endif

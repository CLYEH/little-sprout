#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview`／`TapTargetGateHarness` 用的假 `AlbumsAPIClient`——不打真網路
/// （同 `PreviewTimelineAPIClient` 的角色，見該檔）。生產路徑一律用 `SupabaseAlbumsAPIClient`。
private final class PreviewAlbumsAPIClient: AlbumsAPIClient, @unchecked Sendable {
    func fetchAlbums(familyID: UUID, cursor: AlbumsCursor?, limit: Int) async throws -> [AlbumListingRow] { [] }
    func fetchAlbumMediaLinks(albumIds: [UUID]) async throws -> [AlbumMediaLinkRow] { [] }
    func fetchAlbumChildren(albumIds: [UUID]) async throws -> [AlbumChildLinkRow] { [] }
    func fetchMedia(ids: [UUID]) async throws -> [MediaRow] { [] }
    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] { [:] }
    func createAlbum(familyID: UUID, title: String) async throws -> AlbumListingRow {
        AlbumListingRow(id: UUID(), title: title, coverMediaId: nil, createdAt: Date())
    }
    func setAlbumChildren(albumID: UUID, childIDs: [UUID]) async throws {}
}

extension AlbumsStore {
    @MainActor
    static func preview() -> AlbumsStore {
        AlbumsStore(apiClient: PreviewAlbumsAPIClient())
    }
}
#endif

#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview` 用的假 `TimelineAPIClient`——不打真網路（同 `PreviewChildAPIClient`
/// 的角色，見該檔）。生產路徑一律用 `SupabaseTimelineAPIClient`。
private final class PreviewTimelineAPIClient: TimelineAPIClient, @unchecked Sendable {
    func fetchTimelinePointers(
        familyID: UUID, childID: UUID?, cursor: TimelineCursor?, limit: Int
    ) async throws -> [TimelineFeedPointer] { [] }

    func fetchDiaries(ids: [UUID]) async throws -> [DiaryRow] { [] }
    func fetchDiaryMediaLinks(diaryIds: [UUID]) async throws -> [DiaryMediaLinkRow] { [] }
    func fetchAlbums(ids: [UUID]) async throws -> [AlbumRow] { [] }
    func fetchMedia(ids: [UUID]) async throws -> [MediaRow] { [] }
    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] { [:] }
}

extension TimelineStore {
    @MainActor
    static func preview() -> TimelineStore {
        TimelineStore(apiClient: PreviewTimelineAPIClient())
    }
}
#endif

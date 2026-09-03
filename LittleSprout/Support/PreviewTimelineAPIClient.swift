#if DEBUG
import AVFoundation
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

    /// merge-review `443ec21a` §3「補徽章高度／右緣斷言型測試」：UI test（`XCUITest`，跟被測
    /// app 分離的獨立行程，見 `TapTargetGateHarness.swift` 檔頭註解）沒有真網路，也讀不到
    /// accessibility tree 以外的東西——要讓 `DiaryCardView` 的無縮圖舊影片格顯示「影片
    /// M:SS」（而不是永遠停在「影片」）才能量到真正的、可能換行的最壞情況文字寬度，需要一個
    /// 立即回傳固定時長的 `durationLoader`，不必真的打 `AVURLAsset` 對假 URL 探測（會失敗）。
    @MainActor
    static func preview(durationLoader: @escaping @Sendable (URL) async throws -> CMTime) -> TimelineStore {
        TimelineStore(apiClient: PreviewTimelineAPIClient(), durationLoader: durationLoader)
    }
}
#endif

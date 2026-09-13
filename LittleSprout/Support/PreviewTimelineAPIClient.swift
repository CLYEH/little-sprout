#if DEBUG
import AVFoundation
import Foundation

/// 只給 SwiftUI `#Preview` 用的假 `TimelineAPIClient`——不打真網路（同 `PreviewChildAPIClient`
/// 的角色，見該檔）。生產路徑一律用 `SupabaseTimelineAPIClient`。
///
/// LS-246（票文範圍 1）：三個 seed 參數皆預設空——既有呼叫端（`.preview()`／
/// `.preview(durationLoader:)`）行為不變。`DiaryDetailView.photos` 是透過
/// `TimelineStore.loadDiaryPhotos(diaryID:)`（`TimelineContentAssembler.fetchDiaryPhotos`）
/// 非同步查出來的，不像 `DiaryCardView`（`previewPhotos` 直接建構傳入）能繞過 API client——
/// `TapTargetGateHarness+Safety.swift` 的 `diaryDetailWithVideoHost`（影片 fullScreenCover／
/// 留言 sheet 互斥 UITest 用）需要瀑布流真的有一支「可播放」的影片格（`MasonryPhotoWallView
/// .isPlayableVideo`：`type == .video && signedURL != nil`），才需要讓這個假 client 真的能
/// 回傳種好的 `diary_media` 連結／`media` 列／簽名 URL。
private final class PreviewTimelineAPIClient: TimelineAPIClient, @unchecked Sendable {
    private let diaryMediaLinks: [DiaryMediaLinkRow]
    private let mediaRows: [MediaRow]
    private let signedURLsByStoragePath: [String: URL]
    /// LS-246：`diaryDetailWithVideoHost` 專用——非 0 時 `signedURLs` 先睡這麼久才回傳，讓
    /// UITest 有穩定的視窗可以在「點影片、簽名回來之前」先觸發另一個來源（例如留言鈕），
    /// 決定性地重現「兩個來源非同步窗口重疊」而不必依賴真網路延遲的不確定時序。
    private let signDelayNanoseconds: UInt64

    init(
        diaryMediaLinks: [DiaryMediaLinkRow] = [], mediaRows: [MediaRow] = [],
        signedURLsByStoragePath: [String: URL] = [:], signDelayNanoseconds: UInt64 = 0
    ) {
        self.diaryMediaLinks = diaryMediaLinks
        self.mediaRows = mediaRows
        self.signedURLsByStoragePath = signedURLsByStoragePath
        self.signDelayNanoseconds = signDelayNanoseconds
    }

    func fetchTimelinePointers(
        familyID: UUID, childID: UUID?, cursor: TimelineCursor?, limit: Int
    ) async throws -> [TimelineFeedPointer] { [] }

    func fetchDiaries(ids: [UUID]) async throws -> [DiaryRow] { [] }
    func fetchDiaryMediaLinks(diaryIds: [UUID]) async throws -> [DiaryMediaLinkRow] {
        diaryMediaLinks.filter { diaryIds.contains($0.diaryId) }
    }
    func fetchAlbums(ids: [UUID]) async throws -> [AlbumRow] { [] }
    func fetchMedia(ids: [UUID]) async throws -> [MediaRow] { mediaRows.filter { ids.contains($0.id) } }
    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] {
        if signDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: signDelayNanoseconds)
        }
        return signedURLsByStoragePath.filter { paths.contains($0.key) }
    }
    func reactionCounts(familyID: UUID, targetType: String, targetIDs: [UUID]) async throws -> [ReactionCountRow] { [] }
    func toggleReaction(familyID: UUID, targetType: String, targetID: UUID) async throws -> Bool { true }
    func reactors(familyID: UUID, targetType: String, targetID: UUID) async throws -> [ReactorRow] { [] }
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

    /// LS-246：見上方 `PreviewTimelineAPIClient` 文件註解——`diaryDetailWithVideoHost` 專用，
    /// 讓 `DiaryDetailView.loadDiaryPhotos` 真的查得到一支可播放影片。`video.thumbPath` 呼叫端
    /// 固定傳 `nil`，`TimelineContentAssembler.displayPath` 因此退回 `storagePath`——跟
    /// `signFullSizeURL`（放大播放時現簽同一個 `storagePath`）用的是同一把 key，一份
    /// `signedURLsByStoragePath` 就同時滿足「列表縮圖簽名」與「播放現簽全尺寸」兩次呼叫。
    /// `signDelayNanoseconds` 見 `PreviewTimelineAPIClient` 該屬性文件註解，預設 0（不影響其他
    /// 呼叫端）。
    @MainActor
    static func preview(
        diaryID: UUID, video: MediaRow, signedURL: URL, signDelayNanoseconds: UInt64 = 0
    ) -> TimelineStore {
        TimelineStore(apiClient: PreviewTimelineAPIClient(
            diaryMediaLinks: [DiaryMediaLinkRow(diaryId: diaryID, mediaId: video.id, sortOrder: 0)],
            mediaRows: [video],
            signedURLsByStoragePath: [video.storagePath: signedURL],
            signDelayNanoseconds: signDelayNanoseconds
        ))
    }
}
#endif

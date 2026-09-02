import AVFoundation
import Foundation
import Observation

/// `TimelineStore` 各非同步動作共用的狀態機，同 `ChildOperationState`／`FamilyStore.
/// FamilyOperationState` 的角色。
enum TimelineOperationState: Equatable {
    case idle
    case submitting
    case success
    case failure(AppError)

    var isSubmitting: Bool { self == .submitting }
}

/// 時間軸（LS-126）的 `@Observable` 狀態管理——把 `TimelineAPIClient` 包成畫面能直接讀狀態
/// 驅動重繪的 store（同 `ChildrenStore` 之於 `ChildAPIClient` 的角色）。
@MainActor
@Observable
final class TimelineStore {
    /// `get_family_timeline` 上界夾到 100、預設 20（docs/API.md）；這裡跟後端預設值一致，
    /// 不是隨意選的數字。
    static let pageSize = 20

    private let apiClient: TimelineAPIClient

    private(set) var entries: [TimelineEntry] = []
    private(set) var refreshState: TimelineOperationState = .idle
    private(set) var loadMoreState: TimelineOperationState = .idle
    private(set) var hasMorePages = true
    /// 影片時長（秒）——`media` 表沒有 `duration` 欄位，首次要顯示「影片 M:SS」徽章時才
    /// 向簽名 URL 指向的檔案讀 `AVURLAsset` 時長，讀過的結果快取在這裡，同一支影片不重複讀
    /// （見 `loadVideoDuration`）。
    private(set) var videoDurations: [UUID: TimeInterval] = [:]

    private var familyID: UUID?
    private var childID: UUID?
    private var loadingDurations: Set<UUID> = []

    init(apiClient: TimelineAPIClient) {
        self.apiClient = apiClient
    }

    /// 第一頁／篩選條件改變時呼叫——整批換掉 `entries`。
    @discardableResult
    func refresh(familyID: UUID, childID: UUID?) async -> Bool {
        guard !refreshState.isSubmitting else { return false }
        self.familyID = familyID
        self.childID = childID
        refreshState = .submitting
        do {
            let pointers = try await apiClient.fetchTimelinePointers(
                familyID: familyID, childID: childID, cursor: nil, limit: Self.pageSize
            )
            entries = try await TimelineContentAssembler.assemble(pointers: pointers, apiClient: apiClient)
            hasMorePages = pointers.count == Self.pageSize
            refreshState = .success
            return true
        } catch {
            refreshState = .failure(AppError.map(error))
            return false
        }
    }

    /// 捲到底載入下一頁——沿用 `refresh` 記下的 `familyID`／`childID`，游標取自目前最後一筆
    /// （`get_family_timeline` 回傳序＝`(occurred_at desc, ref_id desc)`，最後一筆就是最舊的
    /// 那一筆）。
    @discardableResult
    func loadMore() async -> Bool {
        guard !loadMoreState.isSubmitting, !refreshState.isSubmitting, hasMorePages else { return false }
        guard let familyID, let last = entries.last else { return false }
        loadMoreState = .submitting
        do {
            let cursor = TimelineCursor(occurredAt: last.occurredAt, refId: last.refId)
            let pointers = try await apiClient.fetchTimelinePointers(
                familyID: familyID, childID: childID, cursor: cursor, limit: Self.pageSize
            )
            let newEntries = try await TimelineContentAssembler.assemble(pointers: pointers, apiClient: apiClient)
            entries.append(contentsOf: newEntries)
            hasMorePages = pointers.count == Self.pageSize
            loadMoreState = .success
            return true
        } catch {
            loadMoreState = .failure(AppError.map(error))
            return false
        }
    }

    /// 日記詳情開頁時呼叫——拿這篇日記**全部**附照（時間軸卡片只帶前 3 張預覽，見
    /// `TimelineContentAssembler.fetchDiaryPhotos` 文件註解）。
    func loadDiaryPhotos(diaryID: UUID) async throws -> [MediaContent] {
        try await TimelineContentAssembler.fetchDiaryPhotos(diaryID: diaryID, apiClient: apiClient)
    }

    /// 登出時歸零——同 `ChildrenStore.reset()`／`FamilyStore.reset()` 的角色。
    func reset() {
        entries = []
        refreshState = .idle
        loadMoreState = .idle
        hasMorePages = true
        videoDurations = [:]
        loadingDurations = []
        familyID = nil
        childID = nil
    }

    /// 讀一支影片的時長並快取；已經讀過或正在讀的 id 直接跳過（避免同一支影片的卡片
    /// 多次觸發 `.task` 時重複打 Storage）。讀取失敗（例如檔案格式看不懂、網路失敗）時
    /// 靜默放棄——呼叫端（`videoDurations[id]` 仍是 nil）退回只顯示「影片」不帶秒數，
    /// 不是整張卡片失敗。
    func loadVideoDuration(mediaID: UUID, url: URL) async {
        guard videoDurations[mediaID] == nil, !loadingDurations.contains(mediaID) else { return }
        loadingDurations.insert(mediaID)
        defer { loadingDurations.remove(mediaID) }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isValid, !duration.isIndefinite else { return }
        videoDurations[mediaID] = CMTimeGetSeconds(duration)
    }
}

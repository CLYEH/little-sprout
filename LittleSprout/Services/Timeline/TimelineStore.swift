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
    /// 世代計數器（merge-review R1 M1／M2）：每次 `refresh` 呼叫都遞增並記下自己的世代號，
    /// await 回來要寫回 `entries`／`hasMorePages`／`refreshState`（或 `loadMoreState`）前
    /// 先確認世代號仍等於目前最新——不等於就代表這次呼叫已經被更新的一次 `refresh` 取代，
    /// 安靜丟棄結果，不寫回過期資料，也不誤把「被取代」寫成 `.failure`。
    ///
    /// 取代舊做法（`guard !refreshState.isSubmitting else { return false }`）：舊做法會讓
    /// 「换了 `childID` 的新呼叫」被還在飛的舊呼叫擋下、連參數（`self.childID`）都沒被記錄
    /// ——使用者切換 `ChildFilterBar` 時第一頁若還沒回來，新的篩選會整個不生效，畫面停在
    /// 舊篩選內容或空狀態，直到使用者再互動一次。`loadMore` 同理沿用同一個世代號：`refresh`
    /// 若在 `loadMore` 飛在半空時把 `entries` 換成新的基底，`loadMore` 用舊游標查到的結果
    /// 已經不對應任何有效分頁位置，靠世代號檢查讓它作廢，不會 `append` 到新列表後面造成
    /// 跳項／混篩選／重複 id。
    private var generation = 0

    init(apiClient: TimelineAPIClient) {
        self.apiClient = apiClient
    }

    /// 第一頁／篩選條件改變時呼叫——整批換掉 `entries`。刻意**不**用 `isSubmitting` 擋重入
    /// （見上方 `generation` 文件註解）：多個呼叫可以同時在飛，`self.familyID`／
    /// `self.childID` 一律立即記錄，只有世代號最新的那一次的結果會被寫回
    /// `entries`／`hasMorePages`／`refreshState`。
    @discardableResult
    func refresh(familyID: UUID, childID: UUID?) async -> Bool {
        generation += 1
        let myGeneration = generation
        self.familyID = familyID
        self.childID = childID
        refreshState = .submitting
        do {
            let pointers = try await apiClient.fetchTimelinePointers(
                familyID: familyID, childID: childID, cursor: nil, limit: Self.pageSize
            )
            let newEntries = try await TimelineContentAssembler.assemble(pointers: pointers, apiClient: apiClient)
            guard myGeneration == generation else { return false }
            entries = newEntries
            hasMorePages = pointers.count == Self.pageSize
            refreshState = .success
            return true
        } catch {
            guard myGeneration == generation else { return false }
            guard !Task.isCancelled else {
                // 被更新的呼叫取代而取消（同一世代內罕見，通常世代號檢查已經先擋下），
                // 不是真的失敗——不落 `.failure` 誤導使用者，見上方 `generation` 文件註解。
                refreshState = .idle
                return false
            }
            refreshState = .failure(AppError.map(error))
            return false
        }
    }

    /// 捲到底載入下一頁——沿用 `refresh` 記下的 `familyID`／`childID`，游標取自目前最後一筆
    /// （`get_family_timeline` 回傳序＝`(occurred_at desc, ref_id desc)`，最後一筆就是最舊的
    /// 那一筆）。世代號在呼叫當下就記錄（不遞增，只有 `refresh` 遞增）：等待期間若有新的
    /// `refresh` 把 `entries` 換成別的基底，這批結果就已經不對應任何有效分頁位置，寫回前的
    /// 世代號檢查會讓它安靜作廢。仍保留 `!loadMoreState.isSubmitting` 擋同一世代內的重複呼叫
    /// （例如捲動觸發器意外重入兩次）——這條跟 M1 是不同的情境，同參數重入本來就該擋。
    @discardableResult
    func loadMore() async -> Bool {
        guard !loadMoreState.isSubmitting, hasMorePages, let familyID, let last = entries.last else { return false }
        let myGeneration = generation
        loadMoreState = .submitting
        do {
            let cursor = TimelineCursor(occurredAt: last.occurredAt, refId: last.refId)
            let pointers = try await apiClient.fetchTimelinePointers(
                familyID: familyID, childID: childID, cursor: cursor, limit: Self.pageSize
            )
            let newEntries = try await TimelineContentAssembler.assemble(pointers: pointers, apiClient: apiClient)
            guard myGeneration == generation else {
                // entries 基底已經被更新的 refresh 換掉——安靜丟棄，但要把 loadMoreState
                // 收回非 submitting，不然下一次使用者捲到底會被卡住的 in-flight guard
                // 永久擋住（見上方 `generation` 文件註解）。
                loadMoreState = .idle
                return false
            }
            entries.append(contentsOf: newEntries)
            hasMorePages = pointers.count == Self.pageSize
            loadMoreState = .success
            return true
        } catch {
            guard myGeneration == generation else {
                loadMoreState = .idle
                return false
            }
            guard !Task.isCancelled else {
                loadMoreState = .idle
                return false
            }
            loadMoreState = .failure(AppError.map(error))
            return false
        }
    }

    /// 日記詳情開頁時呼叫——拿這篇日記**全部**附照（時間軸卡片只帶前 3 張預覽，見
    /// `TimelineContentAssembler.fetchDiaryPhotos` 文件註解）。
    func loadDiaryPhotos(diaryID: UUID) async throws -> [MediaContent] {
        try await TimelineContentAssembler.fetchDiaryPhotos(diaryID: diaryID, apiClient: apiClient)
    }

    /// 登出時歸零——同 `ChildrenStore.reset()`／`FamilyStore.reset()` 的角色（merge-review
    /// R1 M5：接上 `SettingsView.signOut()`，見該檔）。世代號一併遞增：任何還在飛、屬於
    /// 上一個帳號的 `refresh`／`loadMore` 呼叫回來時，世代號檢查會讓它們視為過期而作廢，
    /// 不會在登出後把上一個家庭的照片（簽名 URL 1 小時內仍可讀）寫回畫面。
    func reset() {
        entries = []
        refreshState = .idle
        loadMoreState = .idle
        hasMorePages = true
        videoDurations = [:]
        loadingDurations = []
        familyID = nil
        childID = nil
        generation += 1
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

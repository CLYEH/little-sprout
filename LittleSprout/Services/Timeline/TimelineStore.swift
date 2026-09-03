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
    /// R2-M1（merge-review `b7ecfbf4`）：`loadVideoDuration` 讀時長的實際動作抽成可注入的
    /// 閉包，預設是真正的 `AVURLAsset(url:).load(.duration)`——只有這樣測試才能斷言「同一個
    /// mediaID 兩次呼叫只真正嘗試載入一次」（`failedDurations` 擋第二次），不必真的打網路
    /// 也不用等 AVFoundation 對一個必失敗的 URL 逾時。
    private let durationLoader: @Sendable (URL) async throws -> CMTime

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
    /// R2-M1：讀取時長失敗過的 id——`loadVideoDuration` 原本失敗後什麼都不記，LS-130 讓
    /// 有縮圖的影片必定走進這條失敗路徑（`signedURL` 對它們是縮圖 JPEG，不是可解出時長的
    /// 影片檔），`.task(id:)` 隨卡片重建（例如捲出、捲回 `LazyVStack` 存活視窗）就會重跑，
    /// 沒有這個集合會讓請求數隨捲動次數線性成長——直接抵銷本票要爭取的 egress。呼叫端另外
    /// 用 `MediaContent.isThumbnail` 從源頭跳過縮圖列（見 `PhotoCardView`／
    /// `MasonryPhotoWallView`），這裡的集合是給其他真正失敗的情況（檔案格式看不懂、網路失敗
    /// 等既有情境）通用的硬化，兩者互補、不互斥。
    private var failedDurations: Set<UUID> = []
    /// 世代計數器（merge-review R1 M1／M2；R2-M1 修正）：每次 `refresh` 呼叫都遞增並記下
    /// 自己的世代號，await 回來要寫回 `entries`／`hasMorePages`／`refreshState`（或
    /// `loadMoreState`）前先確認世代號仍等於目前最新——不等於就代表這次呼叫已經被更新的
    /// 一次 `refresh` 取代，安靜丟棄結果，不寫回過期資料，也不誤把「被取代」寫成 `.failure`。
    ///
    /// 取代舊做法（`guard !refreshState.isSubmitting else { return false }`）：舊做法會讓
    /// 「换了 `childID` 的新呼叫」被還在飛的舊呼叫擋下、連參數（`self.childID`）都沒被記錄
    /// ——使用者切換 `ChildFilterBar` 時第一頁若還沒回來，新的篩選會整個不生效，畫面停在
    /// 舊篩選內容或空狀態，直到使用者再互動一次。
    ///
    /// **世代號單獨用在 `loadMore` 不夠**（merge-review R2-M1）：世代號只在 `refresh`
    /// **開始**時遞增，`refresh` **完成**時不會再動它。若 `loadMore` 是在一個 `refresh`
    /// 已經開始、但還沒完成的期間才起跑，兩者會拿到**同一個**世代號——`refresh` 完成後把
    /// `entries` 整批換掉，`loadMore` 稍後回來時世代號檢查依然通過（因為世代號沒有變），
    /// 就會把用「舊 `entries.last` 算出的游標」查到的頁 `append` 到已經被換成別的基底的
    /// `entries` 後面（跳項／混篩選／重複 id）。修法：`loadMore` 額外釘住自己出發當下
    /// `entries` 的尾端身分（`baseTailID`），寫回前**世代號與尾端身分都要吻合**才算數——
    /// 光世代號吻合不夠，因為它答不出「entries 有沒有在我等待期間被別的呼叫整批換掉」
    /// 這個問題，只有尾端身分能直接回答。
    private var generation = 0

    init(
        apiClient: TimelineAPIClient,
        durationLoader: @escaping @Sendable (URL) async throws -> CMTime = { url in
            try await AVURLAsset(url: url).load(.duration)
        }
    ) {
        self.apiClient = apiClient
        self.durationLoader = durationLoader
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
    /// 那一筆）。世代號與「出發當下的尾端身分」都在呼叫當下記錄（都不遞增，只有 `refresh`
    /// 遞增世代號）：寫回前兩者都要吻合目前現況，任一個對不上就代表 `entries` 已經被
    /// 別的呼叫換過基底，這批結果不再對應任何有效分頁位置，安靜作廢（見上方 `generation`
    /// 文件註解的 R2-M1 段——世代號單獨用不夠，見該處理由）。仍保留
    /// `!loadMoreState.isSubmitting` 擋同一世代內的重複呼叫（例如捲動觸發器意外重入兩次）
    /// ——這條跟 M1／R2-M1 是不同的情境，同參數重入本來就該擋。
    @discardableResult
    func loadMore() async -> Bool {
        guard !loadMoreState.isSubmitting, hasMorePages, let familyID, let last = entries.last else { return false }
        let myGeneration = generation
        let baseTailID = last.id
        loadMoreState = .submitting
        do {
            let cursor = TimelineCursor(occurredAt: last.occurredAt, refId: last.refId)
            let pointers = try await apiClient.fetchTimelinePointers(
                familyID: familyID, childID: childID, cursor: cursor, limit: Self.pageSize
            )
            let newEntries = try await TimelineContentAssembler.assemble(pointers: pointers, apiClient: apiClient)
            guard myGeneration == generation, entries.last?.id == baseTailID else {
                // entries 基底已經被更新的呼叫換掉——安靜丟棄，但要把 loadMoreState
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
            guard myGeneration == generation, entries.last?.id == baseTailID else {
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

    /// 放大檢視／播放影片當下才呼叫——現簽一次全尺寸原檔 URL，不在列表／照片牆載入時
    /// 就簽（LS-130，docs/API.md §6「簽名 URL 與 egress 防線」：全尺寸只在放大檢視／
    /// 影片播放時才簽）。`storagePath` 來自呼叫端手上的 `MediaContent.storagePath`
    /// （`fetchDiaryPhotos` 已經帶著，不必重查 `media` 列）。簽名失敗（例如檔案剛好被
    /// 硬刪）時回傳 nil，呼叫端不播放（同既有「簽名失敗擋 tap」慣例，見
    /// `MasonryPhotoWallView.isPlayableVideo`）。
    func signFullSizeURL(storagePath: String) async throws -> URL? {
        let signed = try await apiClient.signedURLs(forStoragePaths: [storagePath])
        return signed[storagePath]
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
        failedDurations = []
        familyID = nil
        childID = nil
        generation += 1
    }

    #if DEBUG
    /// merge-review R2 M1 回歸測試用：`entries` 是 `private(set)`，只能從本檔（`TimelineStore`
    /// 的主宣告）寫入，同 `FamilyStore.seedMyFamilyForPreview` 的角色與理由（見該檔）——UI test
    /// 需要時間軸上有一張可點的日記卡才能真的 push 進 `DiaryDetailView`，`PreviewTimelineAPIClient`
    /// 的 `fetchTimelinePointers` 固定回傳 `[]`，無法靠正常 `refresh()` 流程餵資料。整支 `#if DEBUG`
    /// 圍住，同 `seedMyFamilyForPreview` 的圍欄理由，Release build 不會編到。
    @MainActor
    func seedForPreview(entries: [TimelineEntry]) {
        self.entries = entries
        refreshState = .success
        hasMorePages = false
    }
    #endif

    /// 讀一支影片的時長並快取；已經讀過、正在讀、或讀過且失敗的 id 直接跳過（避免同一支
    /// 影片的卡片多次觸發 `.task` 時重複打 Storage——R2-M1：失敗也要記，不是只記成功，見
    /// `failedDurations` 文件註解）。讀取失敗（例如檔案格式看不懂、網路失敗、縮圖 JPEG 本來
    /// 就解不出時長）時靜默放棄——呼叫端（`videoDurations[id]` 仍是 nil）退回只顯示「影片」
    /// 不帶秒數，不是整張卡片失敗。
    func loadVideoDuration(mediaID: UUID, url: URL) async {
        guard videoDurations[mediaID] == nil, !loadingDurations.contains(mediaID),
              !failedDurations.contains(mediaID) else { return }
        loadingDurations.insert(mediaID)
        defer { loadingDurations.remove(mediaID) }
        guard let duration = try? await durationLoader(url), duration.isValid, !duration.isIndefinite else {
            failedDurations.insert(mediaID)
            return
        }
        videoDurations[mediaID] = CMTimeGetSeconds(duration)
    }
}

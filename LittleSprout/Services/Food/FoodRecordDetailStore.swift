import Foundation
import Observation

/// 記錄詳情的照片狀態。
enum FoodRecordDetailPhotoState: Equatable {
    /// `media_id` 為 null——04b 空白沖印品。
    case none
    /// 有 `media_id`、簽名 URL 還沒回來。
    case loading
    case loaded(URL)
    /// 有 `media_id` 但看不到（已軟刪、簽名失敗、或讀取出錯）——照片窗留 `$surface-2` 空白，
    /// 不退回 04b 的「加照片」邀請（這筆記錄確實有照片，只是這裡顯示不出來）。
    case unavailable
}

/// 記錄詳情 04（LS-381）的 `@Observable` 狀態——view-scoped，每次推入詳情建一份（同 `FoodBookStore`）。
///
/// 畫面一開就先用呼叫端（圖鑑格子）帶進來的那一筆顯示（不等網路、不閃 ProgressView），`refresh()` 再平行做三件事：
/// 1. `list_child_food_records` 重讀——詳情開著的時候記錄可能已被 owner 刪掉（`isGone`）或被作者改過
///    （換照片／反應／備註），用最新那筆取代；
/// 2. 照片簽名 URL（`media_id` 非 null 時）；
/// 3. 記錄者顯示名稱。
/// 2／3 先用手上那筆的 `media_id`／`author_id` 發出去，不排在 1 後面多等一趟來回；1 回來後若 `media_id`
/// 變了，再補簽一次新照片（`author_id` 不會變：更新路徑只開內容四欄）。
///
/// **併發**：`refresh()` 以 `isRefreshing` 防重入（同 `FoodBookStore.refresh()`）；寫回前都比對
/// 「目前這筆的 `media_id` 還是不是發出請求時那個」，避免慢回來的舊照片蓋掉新照片。整個 store 綁在畫面
/// `@State`，畫面離開時 `.task` 取消、store 隨之釋放——照片載入中離開不會寫到別的畫面。
@MainActor
@Observable
final class FoodRecordDetailStore {
    private let foodAPIClient: FoodAPIClient
    private let detailAPIClient: (any FoodRecordDetailAPIClient)?

    private(set) var record: ChildFoodRecord
    /// 重讀後這筆已不在未刪列表裡（被 owner／作者軟刪）——畫面據此返回圖鑑。
    private(set) var isGone = false
    private(set) var photo: FoodRecordDetailPhotoState
    /// `nil`＝還沒查到或查不到（「〇〇記錄」整行隱藏）。
    private(set) var authorName: String?
    /// 最近一次重讀記錄失敗（照片／名稱失敗不算：那兩樣各自退回空白，不擋主要內容）。
    private(set) var refreshError: AppError?
    private(set) var isRefreshing = false

    init(record: ChildFoodRecord, foodAPIClient: FoodAPIClient, detailAPIClient: (any FoodRecordDetailAPIClient)?) {
        self.record = record
        self.foodAPIClient = foodAPIClient
        self.detailAPIClient = detailAPIClient
        photo = record.mediaID == nil ? .none : .loading
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let requestedMediaID = record.mediaID
        async let recordsResult = fetchRecords()
        async let photoResult = fetchPhoto(mediaID: requestedMediaID)
        async let nameResult = fetchAuthorName(authorID: record.authorID)
        let records = await recordsResult
        let photoURL = await photoResult
        let name = await nameResult
        guard !Task.isCancelled else { return }

        authorName = name ?? authorName
        switch records {
        case .success(let list):
            refreshError = nil
            guard let latest = list.first(where: { $0.id == record.id }) else {
                isGone = true
                return
            }
            record = latest
        case .failure(let error):
            refreshError = error
        }
        if record.mediaID == requestedMediaID {
            applyPhoto(photoURL, for: requestedMediaID)
        } else {
            let newMediaID = record.mediaID
            photo = newMediaID == nil ? .none : .loading
            let newURL = await fetchPhoto(mediaID: newMediaID)
            guard !Task.isCancelled, record.mediaID == newMediaID else { return }
            applyPhoto(newURL, for: newMediaID)
        }
    }

    private func applyPhoto(_ url: URL?, for mediaID: UUID?) {
        guard mediaID != nil else {
            photo = .none
            return
        }
        photo = url.map(FoodRecordDetailPhotoState.loaded) ?? .unavailable
    }

    private func fetchRecords() async -> Result<[ChildFoodRecord], AppError> {
        do {
            return .success(try await foodAPIClient.listChildFoodRecords(childID: record.childID))
        } catch {
            return .failure(AppError.map(error))
        }
    }

    /// 失敗一律當「看不到」（`nil`）——照片窗留空白，不擋頁面其他內容。
    private func fetchPhoto(mediaID: UUID?) async -> URL? {
        guard let mediaID, let detailAPIClient else { return nil }
        return try? await detailAPIClient.photoURL(mediaID: mediaID)
    }

    private func fetchAuthorName(authorID: UUID?) async -> String? {
        guard let authorID, let detailAPIClient else { return nil }
        return try? await detailAPIClient.displayName(userID: authorID)
    }
}

#if DEBUG
extension FoodRecordDetailStore {
    /// 只給 harness／`#Preview` 用：直接定住照片與記錄者，不走網路（同 `FoodBookStore.seedForPreview`）。
    func seedForPreview(photo: FoodRecordDetailPhotoState, authorName: String?) {
        self.photo = photo
        self.authorName = authorName
    }
}
#endif

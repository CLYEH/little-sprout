import Foundation
import Observation

/// `GrowthStore` 非同步動作的狀態機——同 `ChildOperationState`／`AlbumDetailOperationState`
/// 的角色，見該類型文件註解，這裡不重複。
enum GrowthOperationState: Equatable {
    case idle
    case submitting
    case success
    case failure(AppError)

    var isSubmitting: Bool { self == .submitting }
}

/// 寶貝詳情「成長」區塊（LS-312，`design/littlesprout.pen` `jp6ka`／`DHwk2`／`pjrd7`）的
/// `@Observable` 狀態管理——view-scoped store，每次推入詳情頁建立一份新的（同
/// `AlbumDetailStore` 的角色分工：不像 `ChildrenStore` 那樣隨 app 存活，見該檔文件註解）。
///
/// 本票只讀（`refresh()`）——新增／編輯／刪除量測是 2/2（LS-313）範圍，刻意不在這裡預留寫入
/// 方法（YAGNI，等真的需要時再加，現在猜介面只會猜錯形狀）。
@MainActor
@Observable
final class GrowthStore {
    let childID: UUID
    let childName: String
    let childBirthday: Date
    private let apiClient: GrowthAPIClient
    /// 一次抓齊的上限——demo／實際使用者資料量遠低於這個值；真的超過時曲線只會少畫最舊的
    /// 幾筆，不是崩潰（2/2 記錄列表另外走 `p_before`／`p_before_id` 分頁）。
    private static let fetchLimit = 200

    private(set) var records: [GrowthRecord] = []
    private(set) var loadState: GrowthOperationState = .idle

    init(childID: UUID, childName: String, childBirthday: Date, apiClient: GrowthAPIClient) {
        self.childID = childID
        self.childName = childName
        self.childBirthday = childBirthday
        self.apiClient = apiClient
    }

    /// 04 空狀態 vs. 01/06 有資料版的分流依據——不看 `loadState`（載入失敗時也應該顯示空狀態
    /// 骨架＋錯誤提示，不是整頁換成別的東西）。
    var isEmpty: Bool { records.isEmpty }

    /// LS-312 R2（merge-review R1 M1，orchestrator 裁決）：`ChildGrowthDetailView.
    /// loadIfNeeded()` 用這支判斷「要不要建一顆新 store」——抽成純函式方便單元測試鎖住這個
    /// 決策（`GrowthStoreTests`）：View 本身的 `@State` 語意沒有 ViewInspector 測不到（見該檔
    /// 文件註解）。同一個孩子（parent 重繪／頭像簽名 URL 重簽）不該重建、換孩子（iPad 側欄）
    /// 才該重建。
    static func needsRebuild(current: GrowthStore?, forChildID childID: UUID) -> Bool {
        guard let current else { return true }
        return current.childID != childID
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !loadState.isSubmitting else { return false }
        loadState = .submitting
        do {
            records = try await apiClient.listGrowthRecords(childID: childID, limit: Self.fetchLimit)
            loadState = .success
            return true
        } catch {
            loadState = .failure(AppError.map(error))
            return false
        }
    }

    func latestValue(for metric: GrowthMetric) -> GrowthCurve.LatestValue? {
        GrowthCurve.latestValue(for: metric, records: records)
    }

    func curvePoints(for metric: GrowthMetric) -> [GrowthCurve.CurvePoint] {
        GrowthCurve.curvePoints(for: metric, records: records, birthday: childBirthday)
    }
}

#if DEBUG
extension GrowthStore {
    /// 只給 `#Preview`／`TapTargetGateHarness` 用：直接種資料，不需要真的走一次 async
    /// `refresh()`（同 `ChildrenStore.seedRoleForPreview` 的既有理由）。
    func seedForPreview(records: [GrowthRecord]) {
        self.records = records
        loadState = .success
    }
}
#endif

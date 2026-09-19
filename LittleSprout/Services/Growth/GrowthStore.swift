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
/// LS-313：新增（`save(id: nil, ...)`）／編輯（`save(id: 非nil, ...)`）／刪除（`delete(id:)`）
/// 三個寫入方法——成功後直接把 `upsertGrowthRecord` 回傳的整列拼進（或替換）本地
/// `records`／從 `records` 移除，不重新打一次 `refresh()`：02／03 儲存或刪除後 01／06 的區塊
/// 與曲線要「即時更新」（票文範圍 3），這裡少一次網路來回，也同時保證 01／02／03 三個畫面讀的
/// 是同一份 `records`（同 store，不需要各自重新載入）。
@MainActor
@Observable
final class GrowthStore {
    let childID: UUID
    let childName: String
    let childBirthday: Date
    private let apiClient: GrowthAPIClient
    /// 一次抓齊的上限——demo／實際使用者資料量遠低於這個值；真的超過時曲線與記錄列表只會少
    /// 畫／少列出最舊的幾筆，不是崩潰。`list_growth_records` 支援的 `p_before`／`p_before_id`
    /// keyset 分頁本票（LS-313）刻意不用：01／02／03 三個畫面共用這一份 `records`，MVP 資料量
    /// （一個孩子頂多幾十筆量測）遠低於這個上限，加一套分頁 UI 是驗收條件沒有要求的猜測性
    /// 複雜度（YAGNI）。
    private static let fetchLimit = 200

    private(set) var records: [GrowthRecord] = []
    private(set) var loadState: GrowthOperationState = .idle
    /// LS-313：02 sheet 儲存鈕四態（idle／submitting／success／failure）讀這個，同
    /// `ChildrenStore.createState`／`.updateState` 的既有慣例——新增與編輯共用同一個狀態
    /// （同一時間只可能有一個 02 sheet 在送出，不需要分開）。
    private(set) var saveState: GrowthOperationState = .idle
    /// LS-313：03 刪除確認共用——`DeleteConfirmationSheet` 自己有一份 `isSubmitting`／
    /// `error` 的區域 `@State`（見該檔），這裡另外存一份是為了讓 01／02 區塊能在刪除失敗時
    /// 也看到同一個錯誤（目前呼叫端只用 `DeleteConfirmationSheet` 自己的錯誤呈現，這個屬性
    /// 保留給 `GrowthStoreTests` 直接鎖住 `delete(id:)` 的狀態轉移，不需要建 View）。
    private(set) var deleteState: GrowthOperationState = .idle

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

    /// LS-312 R3（merge-review R2 M1-a，orchestrator 裁決）：`birthday` 由呼叫端帶入（`child.
    /// birthday`），不吃 `self.childBirthday`——後者只在 store 建立當下寫死一次，`needsRebuild`
    /// 同一個孩子不重建之後就不會再更新；使用者改對生日存檔（同一 `child.id`）之後，曲線月齡軸
    /// 要立刻反映新生日，不能等到換孩子讓 store 重建才對。
    func curvePoints(for metric: GrowthMetric, birthday: Date) -> [GrowthCurve.CurvePoint] {
        GrowthCurve.curvePoints(for: metric, records: records, birthday: birthday)
    }

    /// LS-313：新增（`input.id == nil`）或編輯內容（非 nil）一筆量測——`upsert_growth_record`
    /// 回傳整列，直接拼進（新增）或替換（編輯，依 `id` 找到那一筆）本地 `records`，不重新
    /// `refresh()`（見型別文件註解）。三項量測全部傳 `nil`／`note` 超過 2000 字會撞 `23514`
    /// （`AppError.map` 已映射成 `.validationRetryable`）——02 sheet 呼叫前應該已經用
    /// `GrowthMeasurementValidation` 擋掉全空這個情境，這裡不重複判斷同一件事（表單驗證與
    /// RPC 端的資料庫約束是兩層獨立防線，各自負責，不互相依賴）。收 `GrowthMeasurementInput`
    /// 而不是逐一展開參數——同該型別文件註解，純粹是 SwiftLint `function_parameter_count`
    /// 上限，不是語意需要一個輸入模型。
    @discardableResult
    func save(_ input: GrowthMeasurementInput) async -> Bool {
        guard !saveState.isSubmitting else { return false }
        saveState = .submitting
        do {
            let saved = try await apiClient.upsertGrowthRecord(childID: childID, input: input)
            if let index = records.firstIndex(where: { $0.id == saved.id }) {
                records[index] = saved
            } else {
                records.append(saved)
            }
            saveState = .success
            return true
        } catch {
            saveState = .failure(AppError.map(error))
            return false
        }
    }

    /// 同 `ChildrenStore.resetCreateState()` 的既有理由——02 sheet 重新開啟（新增下一筆／換
    /// 編輯另一筆）時呼叫，把上一次留下的 `.failure` 清乾淨，不讓舊錯誤文案殘留在新的一次
    /// 呈現裡；非 `.failure` 時 no-op（`.success` 不該被這裡悄悄打斷）。
    func resetSaveState() {
        guard case .failure = saveState else { return }
        saveState = .idle
    }

    /// LS-313：軟刪——成功後直接把這筆從本地 `records` 移除，不重新 `refresh()`（見型別文件
    /// 註解）；`records.removeAll` 而非只挑第一筆，理由同「決定性」：`id` 是主鍵，正常情況下
    /// 陣列裡最多一筆符合，這裡用 `removeAll` 純粹是比 `firstIndex`+`remove(at:)` 少一行，
    /// 兩者對這個情境等價。
    @discardableResult
    func delete(id: UUID) async -> Bool {
        guard !deleteState.isSubmitting else { return false }
        deleteState = .submitting
        do {
            try await apiClient.deleteGrowthRecord(id: id)
            records.removeAll { $0.id == id }
            deleteState = .success
            return true
        } catch {
            deleteState = .failure(AppError.map(error))
            return false
        }
    }

    func resetDeleteState() {
        guard case .failure = deleteState else { return }
        deleteState = .idle
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

    /// LS-313：`previewSeededWithDemoRecords()` 種的 6 筆示範資料全部共用這個固定 `authorID`
    /// ——harness／`#Preview` 把「目前登入者」也設成同一個值（見
    /// `ChildGrowthDetailView(previewGrowthStore:currentUserID:)`），03 記錄列表才能同時示範
    /// 「編輯」（僅作者）與「刪除」（作者或 owner）兩種動作列，不需要每次呼叫端各自對一次
    /// 隨機 `UUID()`。`nonisolated`：純常數字面值，不碰任何 `@MainActor` 隔離的可變狀態，讓
    /// `PreviewGrowthAPIClient.upsertGrowthRecord`（nonisolated `async` 協定方法）不需要額外
    /// `await` 就能讀（否則 `GrowthStore` 本身的 `@MainActor` 隔離會擴散到這個 extension）。
    nonisolated static let previewAuthorID = UUID(uuidString: "00000000-0000-0000-0000-0000A0000001") ?? UUID()
}
#endif

import Foundation

/// LS-304：相機膠卷批次匯入「上傳→摘要」（Import 04／04b／05）的批次追蹤器——
/// `AlbumImportUploadCoordinator.startImport(plan:)` 同步回傳這個實例，`entryIDs` 隨著各群
/// PHAsset 讀取／轉檔（非同步）逐步填入，讓 04 進度頁可以立刻掛載（不用等所有群都讀完），
/// 同時知道「這個批次自己入列的項目」是哪些（佇列本身是 app 層級單一實例，可能同時服務其他
/// 批次或單張即傳，見 `AlbumsStore+SharedUploadQueue.swift` 檔頭文件註解）。
///
/// `expectedAssetCount`（04 進度卡「已處理 N/M 張」的 M）在建構當下就固定——直接沿用
/// `ImportPlan.pendingAssetCount`（使用者按下「開始匯入 N 張」看到的同一個數字，畫面數字
/// 契約延續）。**已知限制**：Live Photo 一個 `PHAsset` 展開成「照片＋短片」兩筆佇列項目
/// （票文範圍 2），`entryIDs.count` 最終可能比 `expectedAssetCount` 多——這個落差沒有對應
/// 設計稿處理（LS-251 Notes 從未提到 Live Photo 對「N/M」計數契約的影響），記入 handoff
/// 風險段，不在本票新造文案掩蓋。
@MainActor
@Observable
final class ImportBatchSession {
    private(set) var entryIDs: [UUID] = []
    let expectedAssetCount: Int
    /// 05「共 N 個日期群」副標——只算真的入列的群數（略過的群不算，同 `ImportPlan
    /// .pendingAssetCount` 的排除邏輯）。
    let nonSkippedGroupCount: Int
    /// 已經跑完非同步讀取（不論該群讀出幾筆）的群數——04 進度頁判斷「是否已經知道這個批次
    /// 的完整項目清單」要看這個，不能只看 `entryIDs`：某一群還在讀取中時，`entryIDs` 尚未
    /// 反映那一群的項目，直接拿「目前 entryIDs 是否全部終局」判斷「整批完成」會在其他群
    /// 還沒讀完時提早誤判。`markGroupResolved()` 由 `AlbumImportUploadCoordinator` 在每一群
    /// `store.enqueue(uploads)` 之後呼叫，不論那一群讀到 0 筆或多筆。
    private(set) var resolvedGroupCount = 0
    /// merge-review R1 M2：讀不到／不支援格式／轉檔失敗的 asset 數——`AlbumImportUploadCoordinator
    /// .enqueue(group:...)` 對每個 identifier 讀出 0 筆時累加，不靜默丟（LS-96 池項
    /// `a997f824`(1) 指派本票的處置：比照 `DiaryComposerStore.unsupportedFormatSkippedCount`
    /// ＋回話列同型解法，04／05 用這個數字補一行「N 張沒有加入」）。
    private(set) var droppedCount = 0
    /// merge-review R2 M4：04b「取消整批匯入」確認後設為 true——`AlbumImportUploadCoordinator
    /// .enqueueGroups`／`enqueue` 的兩層迴圈開頭都檢查這個旗標，還沒排到／還沒讀完的群不再
    /// 繼續讀取入列（`Import04ProgressView.onConfirmCancel` 先呼叫 `session.cancel()` 才呼叫
    /// `store.cancelPendingImportItems`，見該檔文件註解）。`ImportBatchSession` 全程只在
    /// MainActor 讀寫（`@MainActor` class），這裡跟 `enqueueGroups`／`enqueue` 的檢查天然
    /// 序列化，不需要額外鎖。
    private(set) var isCancelled = false

    init(expectedAssetCount: Int, nonSkippedGroupCount: Int) {
        self.expectedAssetCount = expectedAssetCount
        self.nonSkippedGroupCount = nonSkippedGroupCount
    }

    func append(_ id: UUID) {
        entryIDs.append(id)
    }

    func markGroupResolved(droppedCount: Int = 0) {
        resolvedGroupCount += 1
        self.droppedCount += droppedCount
    }

    func cancel() {
        isCancelled = true
    }

    var entryIDSet: Set<UUID> { Set(entryIDs) }
    var isFullyEnqueued: Bool { resolvedGroupCount >= nonSkippedGroupCount }

    /// merge-review R2 m1：04b「取消整批匯入」確認對話的「其餘 Y 張不會匯入」——涵蓋還在飛行
    /// 中／失敗（會被 `cancelPendingImportItems` 移除）、格式不支援／讀取失敗（`droppedCount`，
    /// 從未入列）、以及還沒讀到的（`expectedAssetCount` 扣掉已知的），不只是「目前已入列但
    /// 未完成」那些——舊寫法 `batchRows.count - completedCount` 只算得到已入列的部分，跟 04
    /// 「已處理 N/M 張」、05「成功／沒有成功／沒有加入」的 M／dropped 對不起來（票文驗收 4：
    /// 04→04b→05 的 N 一致）。只看 `expectedAssetCount`／`completedCount` 兩個數字就能保證
    /// 跟 04／05 共用同一份「總數」語意，不需要重新推導 dropped／未讀到各自的子數字。
    func remainingCount(completedCount: Int) -> Int {
        max(expectedAssetCount - completedCount, 0)
    }
}

extension UploadQueueStore {
    /// LS-304：批次進度／摘要畫面只關心「這個批次自己入列的項目」，不是佇列裡當下所有活動
    /// （單張即傳／其他批次可能同時在飛）——用 `ImportBatchSession.entryIDSet` 過濾 `rows`，
    /// 保持 `UploadQueueStore` 本身不知道「批次」這個概念（同 `UploadQueueGrouping` 既有的
    /// 「純函式對已知形狀資料做篩選／分組」慣例）。
    func rows(in ids: Set<UUID>) -> [UploadQueueRow] {
        rows.filter { ids.contains($0.id) }
    }

    /// merge-review R1 m1：`retryAllRetryable()` 迭代整個 `order`（不分批次），04／05「重試
    /// 這 N 張」／「重試失敗項（N）」的 N 卻只算這個批次自己的 `rows(in:)`——共用佇列同時
    /// 留有「加入照片」單張即傳的失敗列時，按鈕標的數字跟實際重跑的筆數會對不上。這裡沿
    /// `rows(in:)` 同樣的過濾慣例，只翻批次自己範圍內可重試的失敗列回 `.waiting`。
    func retryRetryable(in ids: Set<UUID>) {
        for id in order where ids.contains(id) {
            guard var entry = entries[id], case .failed(let reason) = entry.state, reason.isRetryable else { continue }
            entry.state = .waiting
            entries[id] = entry
        }
        advance()
    }
}

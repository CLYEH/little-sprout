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

    init(expectedAssetCount: Int, nonSkippedGroupCount: Int) {
        self.expectedAssetCount = expectedAssetCount
        self.nonSkippedGroupCount = nonSkippedGroupCount
    }

    func append(_ id: UUID) {
        entryIDs.append(id)
    }

    func markGroupResolved() {
        resolvedGroupCount += 1
    }

    var entryIDSet: Set<UUID> { Set(entryIDs) }
    var isFullyEnqueued: Bool { resolvedGroupCount >= nonSkippedGroupCount }
}

extension UploadQueueStore {
    /// LS-304：批次進度／摘要畫面只關心「這個批次自己入列的項目」，不是佇列裡當下所有活動
    /// （單張即傳／其他批次可能同時在飛）——用 `ImportBatchSession.entryIDSet` 過濾 `rows`，
    /// 保持 `UploadQueueStore` 本身不知道「批次」這個概念（同 `UploadQueueGrouping` 既有的
    /// 「純函式對已知形狀資料做篩選／分組」慣例）。
    func rows(in ids: Set<UUID>) -> [UploadQueueRow] {
        rows.filter { ids.contains($0.id) }
    }
}

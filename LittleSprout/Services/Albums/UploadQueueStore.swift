import Foundation
import UIKit

/// LS-167：上傳佇列 sheet 的狀態源（`design/littlesprout.pen` `LS-142 / 16 上傳佇列`）。
///
/// **actor 隔離**：整支類別 `@MainActor`——`entries` 只在 MainActor 上被讀寫，`start(_:)`
/// 內建立的 `Task { [weak self] in … }` 是在 MainActor-isolated 方法裡建立的非同步任務，同
/// 檔案慣例（`OTPVerificationModel.beginVerifyRateLimit` 的 `verifyRateLimitTask`）：closure
/// 沒有另外標記 `@Sendable`／`nonisolated`，繼承建立時的 actor context，呼叫
/// `self.finish(...)` 這類同樣 MainActor-isolated 的方法不需要顯式 `await` 跳轉。唯一真正
/// 讓出 MainActor 的地方是 `await self.performUpload(payload:pixelSize:)`（真正的網路
/// I/O）——併發上限
/// （`maxConcurrentUploads`）與 `entries` 的所有讀寫都發生在 MainActor 序列化的執行緒上，
/// 不會有兩個 `start`／`finish` 同時修改同一個 `entries` 陣列的競態。
///
/// **並發上限**：`advance()` 只在「目前上傳中筆數 < maxConcurrentUploads」時才從 `.waiting`
/// 佇列拉新的一筆開始，任何一筆完成（成功或失敗）都會呼叫 `advance()` 遞補下一筆——批次
/// 100 張選圖也只會有 `maxConcurrentUploads` 筆真正同時打 Storage。
///
/// **已知限制**（票文範圍「不做：上傳引擎本身」）：
/// - `MediaUploadService.uploadPhoto`／`uploadVideo` 目前不回報位元組級進度，`uploading`
///   狀態的 `progress` 恆為 `nil`——稿面「上傳中・42%」的即時百分比留給未來另一張碰
///   `MediaUploadService` 本身的票接上真正的進度來源，這裡先把顯示邏輯與測試準備好。
/// - 「已接續先前中斷的上傳」橫幅需要偵測「app 被系統終止、重啟後恢復未完成的上傳」，
///   這需要真正的背景 `URLSession` 續傳（同樣是「上傳引擎本身」），本票只做「使用者主動
///   關閉 sheet 時不取消飛行中的 Task」這一半（`Task` 的生命週期跟著 `UploadQueueStore`
///   實例走，不是跟著 sheet 的 `View` 走——呼叫端只要不提早釋放這個 store 實例，dismiss
///   sheet 不會中斷上傳）；`resumedFromInterruption` 是給呼叫端在偵測到真正中斷時手動
///   設定的旗標，本票沒有任何呼叫端會設它為 `true`。
@MainActor
@Observable
final class UploadQueueStore {
    private struct Entry {
        let thumbnail: UIImage?
        let pixelSize: PixelSize
        /// 上傳用的原始位元組／檔案參照——完成或不可重試失敗後釋放為 `nil`（merge-review
        /// R2 F3：`.photo` 分支的 `Data` 是真正佔記憶體的部分，佇列一次幾十張時全部留著不會
        /// 有人再讀它們）；`thumbnail`／`pixelSize` 這些顯示與型別判斷需要的輕量 metadata
        /// 不受影響，永遠留著。可重試的失敗**不釋放**：`retry(_:)`／`retryAllRetryable()`
        /// 要重新送出同一份位元組，沒有 payload 就沒東西可送。
        var payload: PendingUpload.Kind?
        let enqueuedAt: Date
        var state: UploadItemState
    }

    private let familyID: UUID
    private let mediaUploadService: MediaUploadService
    private let maxConcurrentUploads: Int
    private let now: @MainActor () -> Date
    private var entries: [UUID: Entry] = [:]
    /// 插入順序——`entries` 是字典（用 id 查找／更新方便），排序另外靠這份陣列記住「先進
    /// 佇列的排前面」，不依賴字典本身不保證的走訪順序。
    private var order: [UUID] = []

    /// 稿面 `ImjbJ`：使用者上一次是被系統中斷、這次重新開 sheet 時接續——本票沒有偵測中斷
    /// 的機制（見檔頭「已知限制」），呼叫端可在確實偵測到的情境手動設 `true`。
    var resumedFromInterruption = false

    init(
        familyID: UUID, mediaUploadService: MediaUploadService, maxConcurrentUploads: Int = 3,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.familyID = familyID
        self.mediaUploadService = mediaUploadService
        self.maxConcurrentUploads = maxConcurrentUploads
        self.now = now
    }

    // MARK: - 讀取（View／測試用）

    var rows: [UploadQueueRow] {
        order.compactMap { id in
            guard let entry = entries[id] else { return nil }
            return UploadQueueRow(id: id, enqueuedAt: entry.enqueuedAt, state: entry.state)
        }
    }

    var sections: [UploadQueueSection] { UploadQueueGrouping.sections(for: rows) }

    func thumbnail(for id: UUID) -> UIImage? { entries[id]?.thumbnail }

    /// 「還有 N 張還沒完成」＝等候＋上傳中＋失敗（`design/littlesprout.pen` Handoff Notes
    /// `EUNxh`：完成的不算「還沒完成」）。
    var remainingCount: Int {
        entries.values.reduce(0) { count, entry in
            if case .completed = entry.state { return count }
            return count + 1
        }
    }

    var waitingCount: Int { count { if case .waiting = $0 { true } else { false } } }
    var uploadingCount: Int { count { if case .uploading = $0 { true } else { false } } }

    /// 「重試這 N 張」按鈕文案用（`design/littlesprout.pen` Handoff Notes `iIkHT`）——只算
    /// 可重試的失敗列，不含 LS002。
    var retryableFailedCount: Int {
        count { state in
            if case .failed(let reason) = state { return reason.isRetryable }
            return false
        }
    }

    /// 失敗列總數（含 LS002）——merge-review R2 F5：「全部重試」列只在失敗數 > 1 時顯示
    /// （單一失敗一列自己的重試鈕就夠了，不需要再疊一條批次列），見 `UploadQueueSheetView
    /// .retryAllButton` 呼叫端。
    var failedCount: Int {
        count { if case .failed = $0 { true } else { false } }
    }

    private func count(where predicate: (UploadItemState) -> Bool) -> Int {
        entries.values.reduce(0) { predicate($1.state) ? $0 + 1 : $0 }
    }

    // MARK: - 佇列操作

    /// merge-review R2 F1：同一個 id 已經在 `entries`（等候／上傳中／失敗／完成，任何狀態都
    /// 算）時整筆跳過，不覆寫——沒有這道 guard，呼叫端不慎把同一批（例如使用者對同一次選圖
    /// 手滑連按兩次「加入照片」）重複傳進來時，會用新的 `Entry`（新的 payload、新的
    /// `enqueuedAt`）蓋掉舊的，若舊的正在飛行中（`.uploading`），飛行中的 `Task` 完成時回頭
    /// 呼叫 `finish(id:)` 改的其實是「新蓋上去的那筆」的狀態——對不上真正完成的是哪一次
    /// upload，且 `order` 會多出一個重複的 id（`rows`／`sections` 因此重複列出同一張縮圖）。
    func enqueue(_ uploads: [PendingUpload]) {
        for upload in uploads {
            guard entries[upload.id] == nil else { continue }
            entries[upload.id] = Entry(
                thumbnail: upload.thumbnail, pixelSize: upload.pixelSize, payload: upload.kind,
                enqueuedAt: now(), state: .waiting
            )
            order.append(upload.id)
        }
        advance()
    }

    /// 單列「重試」——LS002 不可重試（見 `UploadFailureReason.isRetryable`），呼叫端理應
    /// 不會對這列顯示重試鈕，這裡再擋一層不信任呼叫端。
    func retry(_ id: UUID) {
        guard var entry = entries[id], case .failed(let reason) = entry.state, reason.isRetryable else { return }
        entry.state = .waiting
        entries[id] = entry
        advance()
    }

    /// 「重試這 N 張」——只重試可重試的失敗列，不動 LS002（`design/littlesprout.pen`
    /// Handoff Notes `hD3dH`：「只重試可重試的（不含 LS002）」）。
    func retryAllRetryable() {
        for id in order {
            guard var entry = entries[id], case .failed(let reason) = entry.state, reason.isRetryable else { continue }
            entry.state = .waiting
            entries[id] = entry
        }
        advance()
    }

    // MARK: - 上傳推進

    private func advance() {
        let capacity = maxConcurrentUploads - uploadingCount
        guard capacity > 0 else { return }
        let waitingIDs = order.filter { id in
            if case .waiting = entries[id]?.state { true } else { false }
        }
        for id in waitingIDs.prefix(capacity) {
            start(id)
        }
    }

    private func start(_ id: UUID) {
        guard var entry = entries[id] else { return }
        // `payload` 為 `nil` 只會發生在完成或不可重試失敗之後（見 `Entry.payload` 文件
        // 註解）——這兩種狀態都不會再被 `advance()` 選中（不是 `.waiting`），理論上走不到
        // 這裡。merge-review R3 i1：R2 版本這裡是靜默 `return`——萬一這個不變量哪天被打破
        // （`.waiting` 卻沒有 payload），這一筆會永遠卡在「等候上傳」，沒有任何錯誤、沒有
        // 前進，使用者跟 QA 都看不出哪裡壞了。改成翻成失敗（Rule 11 fail loud）：至少畫面上
        // 看得到「伺服器忙碌，請稍後再試」，不是無限期的沉默等候。`.server` 是可重試分類，
        // 使用者按「重試」會立刻再次撞進這個分支、再次失敗——不是真的能恢復，但比永遠卡住
        // 誠實，且不會造成無窮迴圈（每次重試都是使用者主動觸發的一次性動作）。
        guard let payload = entry.payload else {
            finish(id, state: .failed(.server))
            return
        }
        entry.state = .uploading(progress: nil)
        let pixelSize = entry.pixelSize
        entries[id] = entry
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.performUpload(payload, pixelSize: pixelSize)
                self.finish(id, state: .completed)
            } catch let error as AppError {
                self.finish(id, state: .failed(.from(error)))
            } catch {
                self.finish(id, state: .failed(.from(AppError.map(error))))
            }
        }
    }

    private func finish(_ id: UUID, state: UploadItemState) {
        guard entries[id] != nil else { return }
        entries[id]?.state = state
        if Self.releasesPayload(for: state) {
            entries[id]?.payload = nil
        }
        advance()
    }

    /// merge-review R2 F3：完成或不可重試失敗的這筆不會再被拿去打網路，`payload` 沒有繼續
    /// 留著的理由；可重試的失敗必須留著給 `retry(_:)`／`retryAllRetryable()` 用。
    private static func releasesPayload(for state: UploadItemState) -> Bool {
        switch state {
        case .completed: true
        case .failed(let reason): !reason.isRetryable
        case .waiting, .uploading: false
        }
    }

    private func performUpload(_ payload: PendingUpload.Kind, pixelSize: PixelSize) async throws -> UUID {
        switch payload {
        case .photo(let data, let fileExtension):
            return try await mediaUploadService.uploadPhoto(
                familyID: familyID, data: data, fileExtension: fileExtension, pixelSize: pixelSize
            )
        case .video(let fileURL, let fileExtension):
            return try await mediaUploadService.uploadVideo(
                familyID: familyID, fileURL: fileURL, fileExtension: fileExtension, pixelSize: pixelSize
            )
        }
    }

    #if DEBUG
    /// 只給 `#Preview`／`TapTargetGateHarness`／UITest 用——直接灌狀態，不經過真正的上傳
    /// 流程（同 `TimelineStore.seedForPreview` 的角色與圍欄理由）。
    struct PreviewSeed {
        let upload: PendingUpload
        let enqueuedAt: Date
        let state: UploadItemState

        init(_ upload: PendingUpload, enqueuedAt: Date, state: UploadItemState) {
            self.upload = upload
            self.enqueuedAt = enqueuedAt
            self.state = state
        }
    }

    func seedForPreview(_ seeds: [PreviewSeed]) {
        for seed in seeds {
            entries[seed.upload.id] = Entry(
                thumbnail: seed.upload.thumbnail, pixelSize: seed.upload.pixelSize, payload: seed.upload.kind,
                enqueuedAt: seed.enqueuedAt, state: seed.state
            )
            order.append(seed.upload.id)
        }
    }

    /// 測試用途：這筆是否還留著上傳用的原始 payload——完成或不可重試失敗後應該是 `nil`
    /// （merge-review R2 F3）。
    func debugPayload(_ id: UUID) -> PendingUpload.Kind? {
        entries[id]?.payload
    }

    /// 測試用途：強制清空某筆的 payload，人為打破「`.waiting` 一定有 payload」這個不變量
    /// （merge-review R3 i1）——正常流程走不到這個狀態，只能用這個鉤子模擬，驗證
    /// `start(_:)` 撞到這個不變量被打破時會翻成失敗，不是永遠卡住。
    func debugForcePayloadNil(_ id: UUID) {
        entries[id]?.payload = nil
    }
    #endif
}

import Foundation
import UIKit

/// LS-167：上傳佇列 sheet 的狀態源（`design/littlesprout.pen` `LS-142 / 16 上傳佇列`）。
///
/// **actor 隔離**：整支類別 `@MainActor`——`entries` 只在 MainActor 上被讀寫，`start(_:)`
/// 內建立的 `Task { [weak self] in … }` 是在 MainActor-isolated 方法裡建立的非同步任務，同
/// 檔案慣例（`OTPVerificationModel.beginVerifyRateLimit` 的 `verifyRateLimitTask`）：closure
/// 沒有另外標記 `@Sendable`／`nonisolated`，繼承建立時的 actor context，呼叫
/// `self.finish(...)` 這類同樣 MainActor-isolated 的方法不需要顯式 `await` 跳轉。唯一真正
/// 讓出 MainActor 的地方是 `await self.performUpload(upload)`（真正的網路 I/O）——併發上限
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
        let upload: PendingUpload
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

    func thumbnail(for id: UUID) -> UIImage? { entries[id]?.upload.thumbnail }

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

    private func count(where predicate: (UploadItemState) -> Bool) -> Int {
        entries.values.reduce(0) { predicate($1.state) ? $0 + 1 : $0 }
    }

    // MARK: - 佇列操作

    func enqueue(_ uploads: [PendingUpload]) {
        for upload in uploads {
            entries[upload.id] = Entry(upload: upload, enqueuedAt: now(), state: .waiting)
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
        entry.state = .uploading(progress: nil)
        entries[id] = entry
        let upload = entry.upload
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.performUpload(upload)
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
        advance()
    }

    private func performUpload(_ upload: PendingUpload) async throws -> UUID {
        switch upload.kind {
        case .photo(let data, let fileExtension):
            return try await mediaUploadService.uploadPhoto(
                familyID: familyID, data: data, fileExtension: fileExtension, pixelSize: upload.pixelSize
            )
        case .video(let fileURL, let fileExtension):
            return try await mediaUploadService.uploadVideo(
                familyID: familyID, fileURL: fileURL, fileExtension: fileExtension, pixelSize: upload.pixelSize
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
            entries[seed.upload.id] = Entry(upload: seed.upload, enqueuedAt: seed.enqueuedAt, state: seed.state)
            order.append(seed.upload.id)
        }
    }
    #endif
}

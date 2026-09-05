import Foundation
import UIKit

/// LS-167（`design/littlesprout.pen` `LS-142 / 16 上傳佇列`）：上傳佇列 sheet 的純資料模型——
/// 不含任何 async I/O，`UploadQueueStore`（`Services/Albums/UploadQueueStore.swift`）是唯一
/// 會真的呼叫 `MediaUploadService` 的地方。拆開的理由同 `DiaryComposerModels.swift` 檔頭慣例：
/// 分群／排序／文案這類純函式不必經過任何 store 或 view 就能被單元測試覆蓋。

/// 佇列裡一張照片／一支影片，還沒上傳前的原始內容——`kind` 只帶各自需要的欄位，
/// 沿用 `DiaryPhotoDraft.Kind` 的形狀（不含 `duration`：日記草稿需要它決定要不要
/// `VideoTrimmer` 裁切，相簿上傳沒有 60 秒限制，不需要這個欄位）。
struct PendingUpload: Identifiable {
    enum Kind {
        case photo(data: Data, fileExtension: String)
        case video(fileURL: URL, fileExtension: String)
    }

    let id: UUID
    let kind: Kind
    /// 佇列列縮圖；來源解碼失敗時允許 nil（同 `DiaryPhotoDraft.previewImage`，UI 端用系統
    /// 圖示佔位）。
    let thumbnail: UIImage?
    let pixelSize: PixelSize

    init(id: UUID = UUID(), kind: Kind, thumbnail: UIImage?, pixelSize: PixelSize) {
        self.id = id
        self.kind = kind
        self.thumbnail = thumbnail
        self.pixelSize = pixelSize
    }
}

/// 佇列裡一張的目前狀態（`design/littlesprout.pen` Handoff Notes `TVLkD`：三語意群組
/// Failed／In Progress／Completed；waiting／uploading 都算 In Progress）。
enum UploadItemState: Equatable {
    case waiting
    /// `progress`：0...1，`MediaUploadService.uploadPhoto`／`uploadVideo` 目前不回報位元組
    /// 級進度（見 `UploadQueueStore` 檔頭「已知限制」段）——這裡保留欄位讓列的顯示邏輯與
    /// 測試現在就能就緒，真正的即時進度留給未來另一張碰 `MediaUploadService` 本身的票接上；
    /// `nil` 代表「正在上傳，但目前沒有可顯示的進度」。
    case uploading(progress: Double?)
    case completed
    case failed(UploadFailureReason)
}

/// 上傳失敗的三分支（`design/littlesprout.pen` Handoff Notes `kfLYA`，LS-96 `f960d843`
/// 教訓「先講發生什麼再講怎麼辦」——三句文案都是「發生了什麼」開頭，動作另外用按鈕／連結
/// 承載，不是文案本身兼職）。
enum UploadFailureReason: Equatable {
    /// `URLError`（`.notConnectedToInternet`／`.networkConnectionLost` 等）。
    case network
    /// 5xx／其他未分類的伺服器錯誤，也是 `.validationRetryable`／`.retryableSystem`／其他
    /// `.rejected` 碼的共用落點——見 `from(_:)` 文件註解「已知不完美之處」。
    case server
    /// LS002（`storage_quota_bytes` 已滿）——`tier` 是 `.rejected`：重試同一次呼叫不會
    /// 成功，稿面刻意不提供「重試」，只給「查看儲存空間」出路。
    case quota

    var title: String {
        switch self {
        case .network: "連線中斷，請檢查網路連線。"
        case .server: "伺服器忙碌，請稍後再試。"
        case .quota: "相簿容量已滿，這張沒有上傳。"
        }
    }

    /// 稿面 kfLYA：LS002 不提供「重試」——換一次呼叫不會變出空間，使用者得先去騰出空間。
    var isRetryable: Bool { self != .quota }

    /// 稿面 hD3dH（MJ-5）：只有 LS002 這一列多一個「查看儲存空間」連結出路。
    var showsQuotaLink: Bool { self == .quota }

    /// `AppError` → 三分支的對應。**已知不完美之處**（設計稿只定義三句文案，沒有第四句）：
    /// `.validationRetryable`（例如 `MediaUploadService.mapUploadError` 的 Storage 413
    /// payload-too-large）與非 LS002 的 `.rejected`（例如帳號／家庭停權中途發生）都落在
    /// `.server` 這個桶——顯示「伺服器忙碌，請稍後再試」＋可重試，但這兩種情況重試同一份
    /// 位元組永遠不會成功。真正的邊界修法需要設計補第四句文案，這裡先用最保守（不會誤導
    /// 成「無法挽回」、頂多讓使用者多按一次無效的重試）的桶接住，未在本票新增第四句文案
    /// ——記入 handoff「未完成」。
    static func from(_ error: AppError) -> UploadFailureReason {
        switch error {
        case .network:
            return .network
        case .rejected(_, let code) where code == LSErrorCode.storageQuotaExceeded.rawValue:
            return .quota
        case .validationRetryable, .retryableSystem, .rejected, .server:
            return .server
        }
    }
}

/// 佇列一列的純顯示資料——`UploadQueueStore.rows` 從 `[PendingUpload]`＋`[UUID: UploadItemState]`
/// 轉出來，View 只認這個型別，不直接碰 store 的內部儲存形狀。刻意不含 `UIImage`（避免 View
/// 相依於解碼細節，也讓「狀態→列模型轉換」的測試不必比較圖片）——縮圖由 View 端另外從
/// `UploadQueueStore` 查。
struct UploadQueueRow: Identifiable, Equatable {
    let id: UUID
    let enqueuedAt: Date
    let state: UploadItemState
}

/// 三語意群組（`design/littlesprout.pen` Handoff Notes `TVLkD`：Group Failed／In
/// Progress／Completed，各自 `layout:vertical gap:$sp-item`，群間 `gap:$sp-block`）。
enum UploadQueueGroupKind: String, CaseIterable {
    case failed
    case inProgress
    case completed

    /// 群標題（`TVLkD`：「沒有成功」／「正在進行」／「已完成」）。
    var title: String {
        switch self {
        case .failed: "沒有成功"
        case .inProgress: "正在進行"
        case .completed: "已完成"
        }
    }
}

struct UploadQueueSection: Identifiable {
    let kind: UploadQueueGroupKind
    let rows: [UploadQueueRow]
    var id: UploadQueueGroupKind { kind }
    var title: String { kind.title }
}

/// 分群與排序（純函式，`UploadQueueGroupingTests` 覆蓋）。
enum UploadQueueGrouping {
    /// `TVLkD`＋`pUvzU`／INFO-N3（R7）：Failed 群「可處理性優先於時間序」——LS002（容量已滿，
    /// 只能靠「查看儲存空間」而非重試解決）固定排最前，其餘可重試的失敗列依時間新到舊排在
    /// 其後；In Progress／Completed 兩群單純依時間新到舊。空群不出現在結果裡（View 端不畫
    /// 沒有內容的群標題）。
    static func sections(for rows: [UploadQueueRow]) -> [UploadQueueSection] {
        let failed = rows.filter { if case .failed = $0.state { true } else { false } }
        let inProgress = rows.filter {
            switch $0.state {
            case .waiting, .uploading: true
            case .completed, .failed: false
            }
        }
        let completed = rows.filter { if case .completed = $0.state { true } else { false } }
        return [
            UploadQueueSection(kind: .failed, rows: sortFailed(failed)),
            UploadQueueSection(kind: .inProgress, rows: newestFirst(inProgress)),
            UploadQueueSection(kind: .completed, rows: newestFirst(completed))
        ].filter { !$0.rows.isEmpty }
    }

    private static func sortFailed(_ rows: [UploadQueueRow]) -> [UploadQueueRow] {
        let quota = newestFirst(rows.filter(isQuota))
        let others = newestFirst(rows.filter { !isQuota($0) })
        return quota + others
    }

    private static func isQuota(_ row: UploadQueueRow) -> Bool {
        if case .failed(.quota) = row.state { return true }
        return false
    }

    private static func newestFirst(_ rows: [UploadQueueRow]) -> [UploadQueueRow] {
        rows.sorted { $0.enqueuedAt > $1.enqueuedAt }
    }
}

/// 「今天 14:29」時間戳文案（`design/littlesprout.pen` Handoff Notes `zejuQ`，MN-4：檔名完全
/// 移除，相對時間戳記是列的主要識別）。稿面只畫了「今天」的樣本；跨到前一天／更早沒有對應
/// 稿面文字，這裡延伸同一組「相對日＋24 小時制時分」語彙，不是照抄稿面沒寫的東西——
/// 也記在 handoff「未完成」，若之後有對應設計稿再對齊。
enum UploadQueueTimestampFormat {
    static func string(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let timeText = timeFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 \(timeText)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(timeText)"
        }
        return "\(dateFormatter.string(from: date)) \(timeText)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "M/d"
        return formatter
    }()
}

import Foundation

/// LS-304：`SupabaseMediaUploadService` 的私有輸入／輸出型別——從 `MediaUploadService.swift`
/// 拆出，理由同 `MediaUploadService+SoftDelete.swift`／`MediaUploadService+Duration.swift` 檔頭
/// 「拆檔理由：SwiftLint file_length」的既有慣例：主檔逼近上限。存取層級從 `private`
/// 放寬成預設（internal）——跨檔案的 extension／同 module 型別存取不到 `private`（以檔案
/// 為界），範圍仍只在本 module 內，不對外公開。
/// 讀本機暫存檔屬性失敗時的內部錯誤——不對應任何後端碼，`AppError.map` 對辨認不出來的型別
/// 一律落 `.server`（fail loud：不會有第五種「未知」分類讓呼叫端誤以為可以安全忽略）。
enum MediaUploadFileError: Error {
    case missingFileSize
}

/// 縮圖產生完成、還沒 PUT 上去之前的暫存值——把「PUT 縮圖用的路徑＋bytes」與「寫進 media
/// 列用的 thumb_width／thumb_height」包在一起，`uploadPhoto`／`uploadVideo` 兩處都不必再
/// 各自把 thumb 路徑／寬／高拆成三個各自照顧的 optional（忘了同步更新其中一個，會讓三個
/// `thumb_*` 欄位互相對不上，撞上 `media_thumb_dimensions_consistency` CHECK）。
struct PendingThumbnail {
    let path: String
    let data: Data
    let pixelSize: PixelSize
}

/// `insertMediaRow` 的輸入分組——把 `storagePath`／`type`／`byteSize`／`pixelSize`／`thumb`
/// 收成一個值，讓呼叫端／被呼叫端都少幾個參數（SwiftLint `function_parameter_count`）。
struct MediaRowDescriptor {
    let storagePath: String
    let type: String
    let byteSize: Int
    let pixelSize: PixelSize
    let thumb: PendingThumbnail?
    /// LS-135：影片時長（整數秒，`max(1, floor(d))`）——`uploadPhoto` 恆傳 `nil`；
    /// `uploadVideo` 傳 `measureDurationSeconds` 的量測結果（可能是 `nil`，量測失敗不阻斷
    /// 上傳，見該函式文件註解）。
    let durationSeconds: Int?
    /// LS-304：`media.taken_at`——見 `MediaUploadService.uploadPhoto` 文件註解。
    let takenAt: Date?
}

struct MediaInsertPayload: Encodable {
    let id: UUID
    let familyID: UUID
    let storagePath: String
    let type: String
    let byteSize: Int
    let width: Int
    let height: Int
    let uploadedBy: UUID
    let thumbPath: String?
    let thumbWidth: Int?
    let thumbHeight: Int?
    let durationSeconds: Int?
    let takenAt: String? // LS-304：`String?` 不是 `Date?`，見 `MediaUploadService+TakenAt.swift`。

    init(id: UUID, familyID: UUID, descriptor: MediaRowDescriptor, uploadedBy: UUID) {
        self.id = id
        self.familyID = familyID
        self.storagePath = descriptor.storagePath
        self.type = descriptor.type
        self.byteSize = descriptor.byteSize
        self.width = descriptor.pixelSize.width
        self.height = descriptor.pixelSize.height
        self.uploadedBy = uploadedBy
        self.thumbPath = descriptor.thumb?.path
        self.thumbWidth = descriptor.thumb?.pixelSize.width
        self.thumbHeight = descriptor.thumb?.pixelSize.height
        self.durationSeconds = descriptor.durationSeconds
        self.takenAt = descriptor.takenAt.map(SupabaseMediaUploadService.iso8601String)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case familyID = "family_id"
        case storagePath = "storage_path"
        case type
        case byteSize = "byte_size"
        case width
        case height
        case uploadedBy = "uploaded_by"
        case thumbPath = "thumb_path"
        case thumbWidth = "thumb_width"
        case thumbHeight = "thumb_height"
        case durationSeconds = "duration_seconds"
        case takenAt = "taken_at"
    }
}

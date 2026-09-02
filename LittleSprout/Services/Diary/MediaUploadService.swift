import AVFoundation
import Foundation
import ImageIO
import Supabase
import UIKit

/// 把日記編輯器選好的一張照片／一支影片，上傳成一筆可掛在日記底下的 `media` 列。
///
/// 三步驟（`docs/API.md` §3 `media`「上傳流程順序很重要」）：① 先把原始檔案 PUT 進 Storage
/// （`media` bucket，見 `supabase/migrations/20260823030000_storage_policies.sql`）②
/// 同步產生縮圖並 PUT 進 Storage（長邊 ≤512px、JPEG 品質 0.8，`docs/API.md` §6）——①②互不
/// 相依，並行 PUT；③ 兩者皆成功後才 `insert` 對應的 `media` 列（`storage_path`／
/// `thumb_path`／`thumb_width`／`thumb_height` 一次寫入，`supabase/migrations/
/// 20260902101842_media_thumb_path.sql` 的一致性 `CHECK` 要求三欄同為 NULL 或同為非
/// NULL）。①②任一步失敗都不 `insert`；呼叫端要自己清掉已上傳的孤兒物件——兩個實作方法
/// 都遵守這個順序，並在失敗時嘗試 `remove` 已上傳的物件（best-effort，見實作註解）。
/// **縮圖產生本身失敗**（來源資料看不懂，不是 PUT 失敗）是唯一不阻斷整體上傳的例外：三個
/// `thumb_*` 欄位留空插入，過渡期讀取端退回原圖（`docs/API.md` §3）。
protocol MediaUploadService: Sendable {
    /// 上傳一張照片；`data` 是已經讀進記憶體的原始位元組（`PhotosPickerItem.loadTransferable`
    /// 讀出來的那份），`fileExtension` 不含點（`jpg`／`heic`…）。回傳新建 `media` 列的 id。
    func uploadPhoto(familyID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize) async throws -> UUID

    /// 上傳一支影片；`fileURL` 是本機暫存檔（呼叫端若先用 `VideoTrimmer` 裁切壓縮過，這裡
    /// 傳裁切後的暫存檔路徑）。回傳新建 `media` 列的 id。
    func uploadVideo(familyID: UUID, fileURL: URL, fileExtension: String, pixelSize: PixelSize) async throws -> UUID
}

final class SupabaseMediaUploadService: MediaUploadService {
    private let client: SupabaseClient
    /// merge-review R1 m1：原檔與縮圖路徑必須共用同一個時間點，見 `uploadPhoto`／`uploadVideo`
    /// 「一次上傳只讀一次 `now()`」的呼叫方式；預設 `Date.init`，測試可注入固定／可控 clock
    /// 釘住「兩條路徑真的共用同一次讀值」（`SupabaseMediaUploadServiceThumbnailTests`）。
    private let now: @Sendable () -> Date
    private static let bucketID = "media"
    /// 縮圖規格（`docs/API.md` §6）：長邊 ≤512px、JPEG 品質 0.8。
    private static let thumbnailMaxPixelSize: CGFloat = 512
    private static let thumbnailJPEGQuality: CGFloat = 0.8
    private static let thumbnailContentType = "image/jpeg"

    init(client: SupabaseClient, now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    func uploadPhoto(familyID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
        let mediaID = UUID()
        // merge-review R1 m1：只讀一次 `now()`，原檔與縮圖路徑共用同一個時間點——見下方
        // `storagePath`／`makePhotoPendingThumbnail` 呼叫都吃這個值，不各自重新讀「現在」。
        let uploadTime = now()
        let path = Self.storagePath(familyID: familyID, mediaID: mediaID, fileExtension: fileExtension, now: uploadTime)
        let pendingThumb = Self.makePhotoPendingThumbnail(
            from: data, familyID: familyID, mediaID: mediaID, now: uploadTime
        )
        do {
            try await uploadOriginalAndThumb(pendingThumb: pendingThumb) { [client] in
                try await client.storage.from(Self.bucketID).upload(
                    path, data: data,
                    options: FileOptions(contentType: Self.contentType(forExtension: fileExtension))
                )
            }
        } catch {
            // 沒有縮圖時只有原檔一個 PUT，這裡的 throw 只可能來自那個 PUT 本身失敗——沒有
            // 任何物件真的上傳成功，不需要（也不該）呼叫 cleanupOrphans 打一次注定落空的
            // DELETE（見 uploadOriginalAndThumb 文件註解「沒有縮圖時只有原檔一個 child
            // task」）。有縮圖時兩個 task 都跑完才會到這裡，任一個都可能已經真的上傳成功，
            // 兩個路徑都要批次清。
            if pendingThumb != nil {
                await cleanupOrphans(path: path, thumbPath: pendingThumb?.path)
            }
            throw Self.mapUploadError(error)
        }
        do {
            try await insertMediaRow(
                id: mediaID, familyID: familyID,
                descriptor: MediaRowDescriptor(
                    storagePath: path, type: "photo", byteSize: data.count, pixelSize: pixelSize, thumb: pendingThumb
                )
            )
        } catch {
            await cleanupOrphans(path: path, thumbPath: pendingThumb?.path)
            throw error
        }
        return mediaID
    }

    func uploadVideo(familyID: UUID, fileURL: URL, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
        let mediaID = UUID()
        // merge-review R1 m1：同 uploadPhoto，只讀一次 `now()`，原檔與縮圖路徑共用同一個時間點。
        let uploadTime = now()
        let path = Self.storagePath(familyID: familyID, mediaID: mediaID, fileExtension: fileExtension, now: uploadTime)
        // merge-review R1 m8：讀不到檔案大小時直接 throw，不要靜默寫 0——`byte_size` 是
        // `families.storage_used_bytes` trigger 的加總來源，寫 0 等於這支影片不佔額度
        // （`init_schema.sql` 對這欄的可信度有明文要求，見協定檔對照）。
        let byteSize: Int
        do {
            byteSize = try Self.fileByteSize(at: fileURL)
        } catch {
            throw AppError.map(error)
        }
        let pendingThumb = Self.makeVideoPendingThumbnail(
            fileURL: fileURL, familyID: familyID, mediaID: mediaID, now: uploadTime
        )
        do {
            try await uploadOriginalAndThumb(pendingThumb: pendingThumb) { [client] in
                try await client.storage.from(Self.bucketID).upload(
                    path, fileURL: fileURL,
                    options: FileOptions(contentType: Self.contentType(forExtension: fileExtension))
                )
            }
        } catch {
            // 見 uploadPhoto 同一段落的文件註解：沒有縮圖時只有原檔一個 PUT，失敗代表沒有
            // 任何物件真的上傳成功，不需要呼叫 cleanupOrphans。
            if pendingThumb != nil {
                await cleanupOrphans(path: path, thumbPath: pendingThumb?.path)
            }
            throw Self.mapUploadError(error)
        }
        do {
            try await insertMediaRow(
                id: mediaID, familyID: familyID,
                descriptor: MediaRowDescriptor(
                    storagePath: path, type: "video", byteSize: byteSize, pixelSize: pixelSize, thumb: pendingThumb
                )
            )
        } catch {
            await cleanupOrphans(path: path, thumbPath: pendingThumb?.path)
            throw error
        }
        return mediaID
    }

    // MARK: - 原檔＋縮圖並行 PUT

    /// 原檔＋縮圖並行 PUT（`docs/API.md` §3「①②互不相依，可以並行 PUT」）。用 `TaskGroup`
    /// 而不是 `async let`——**merge-review R1 i2**：這不是正確性差異。`async let` 的兩個
    /// child task 一樣在**函式 scope 結束**時被隱式 cancel／await，而這裡的 do/catch 在
    /// 呼叫端（`uploadPhoto`／`uploadVideo`），這支函式的 scope 早就結束了，兩種寫法在這個
    /// 形狀下都不會有「`catch` 執行時另一個 child task 還在飛行中」的競態。選 `TaskGroup`
    /// 純粹是因為 child task 數量可變（有沒有縮圖）時寫法更自然，且與
    /// `TimelineContentAssembler.fetchContentMaps` 的既有慣例一致（見該檔文件註解）。沒有
    /// 縮圖（`pendingThumb == nil`，生成失敗的過渡情形）時只有原檔一個 child task，等同單一
    /// PUT。
    private func uploadOriginalAndThumb(
        pendingThumb: PendingThumbnail?, putOriginal: @escaping @Sendable () async throws -> Void
    ) async throws {
        let bucket = client.storage.from(Self.bucketID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await putOriginal() }
            if let pendingThumb {
                group.addTask {
                    try await bucket.upload(
                        pendingThumb.path, data: pendingThumb.data,
                        options: FileOptions(contentType: Self.thumbnailContentType)
                    )
                }
            }
            for try await _ in group {}
        }
    }

    /// ②③失敗時清掉①②已上傳的孤兒物件——best-effort：清理本身失敗不覆蓋原始錯誤（呼叫端
    /// 只在意「這次上傳失敗了」，孤兒物件清不掉是背景衛生問題，見協定檔文件註解）。原檔＋
    /// 縮圖一次 `remove(paths:)` 批次刪，不分兩次打（`StorageFileApi.remove` 本來就接受
    /// 陣列）；沒有 `thumbPath`（縮圖生成失敗的過渡情形，或連原檔都還沒 PUT 就失敗）時只
    /// 清原檔一個。
    private func cleanupOrphans(path: String, thumbPath: String?) async {
        let paths = thumbPath.map { [path, $0] } ?? [path]
        _ = try? await client.storage.from(Self.bucketID).remove(paths: paths)
    }

    private func insertMediaRow(id: UUID, familyID: UUID, descriptor: MediaRowDescriptor) async throws {
        do {
            let session = try await client.auth.session
            let row = MediaInsertPayload(
                id: id, familyID: familyID, descriptor: descriptor, uploadedBy: session.user.id
            )
            try await client.from("media").insert(row).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    /// `{family_id}/{yyyy}/{mm}/{media_id}`（`docs/API.md` §6）：`yyyy/mm` 取**上傳時間**
    /// （UTC，避免裝置時區造成月份邊界判斷不一致）；`family_id`／`media_id` 一律小寫正規形
    /// UUID——`UUID().uuidString` 預設大寫，這裡強制 `.lowercased()`。
    ///
    /// **merge-review R1 m1**：`now` 由呼叫端傳入、這支函式本身不讀「現在」——`storagePath`／
    /// `thumbStoragePath` 各自呼叫一次 `objectPathPrefix`，若各自預設讀一次 `Date()`，剛好跨
    /// UTC 月界時原檔與縮圖會落在不同 `yyyy/mm`（先前版本的錯誤所在：程式碼共用了函式本身，
    /// 但沒有共用「日期讀取」，註解卻宣稱後者也成立）。真正的共用點在
    /// `uploadPhoto`／`uploadVideo`：兩處只呼叫一次 `now()`、把同一個 `Date` 往下傳給
    /// `storagePath` 與 `makePhotoPendingThumbnail`/`makeVideoPendingThumbnail`（→
    /// `thumbStoragePath`），這裡才是「原檔與縮圖共用同一組 `yyyy/mm`」保證成立的地方。
    private static func objectPathPrefix(familyID: UUID, mediaID: UUID, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month], from: now)
        let year = String(format: "%04d", components.year ?? 1970)
        let month = String(format: "%02d", components.month ?? 1)
        return "\(familyID.uuidString.lowercased())/\(year)/\(month)/\(mediaID.uuidString.lowercased())"
    }

    static func storagePath(familyID: UUID, mediaID: UUID, fileExtension: String, now: Date = Date()) -> String {
        "\(objectPathPrefix(familyID: familyID, mediaID: mediaID, now: now)).\(fileExtension.lowercased())"
    }

    /// 縮圖物件路徑（`docs/API.md` §6：`{family_id}/{yyyy}/{mm}/{media_id}_thumb.jpg`）。
    static func thumbStoragePath(familyID: UUID, mediaID: UUID, now: Date = Date()) -> String {
        "\(objectPathPrefix(familyID: familyID, mediaID: mediaID, now: now))_thumb.jpg"
    }

    private static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        default: "application/octet-stream"
        }
    }

    /// Storage 的 `file_size_limit`（50 MiB，
    /// `supabase/migrations/20260823030000_storage_policies.sql`）被撞到時回傳
    /// `statusCode "413"`——`code` 用 `DiaryMediaErrorCode.payloadTooLarge` 這個 client 合成
    /// sentinel 標記，讓畫面層（`DiaryEditorView+ActionBar.swift`）能依 `code` 分流出專屬文案
    /// （merge-review R1 M1：`message` 只供 log／除錯用，不會直接顯示給使用者，見
    /// `AppError.swift` 檔頭契約）；其餘一律走既有 `AppError.map`（涵蓋網路／JWT 過期等既有
    /// 分類）。
    static func mapUploadError(_ error: Error) -> AppError {
        if let storageError = error as? StorageError, storageError.statusCode == "413" {
            return .validationRetryable(
                message: "Storage 413：檔案超過 50 MiB 上限", code: DiaryMediaErrorCode.payloadTooLarge
            )
        }
        return AppError.map(error)
    }

    private static func fileByteSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? Int else {
            throw MediaUploadFileError.missingFileSize
        }
        return size
    }

    // MARK: - 縮圖產生（`docs/API.md` §6：長邊 ≤512px、JPEG 品質 0.8）

    /// 照片縮圖：直接用 `CGImageSource` 從原始 bytes 產生降採樣後的縮圖，不像 `UIImage(data:)`
    /// 那樣得先把整張原圖解碼進記憶體再縮小（同 `PickedItemLoader.downsizedThumbnail` 的既有
    /// 理由，只是這裡操作對象是上傳前的 `Data`，不是已經解碼好的 `UIImage`）。生成失敗（來源
    /// 資料看不懂）回傳 `nil`——呼叫端把它當「這次沒有縮圖」處理，不阻斷原檔上傳。
    private static func makePhotoPendingThumbnail(
        from data: Data, familyID: UUID, mediaID: UUID, now: Date
    ) -> PendingThumbnail? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: thumbnailJPEGQuality) else {
            return nil
        }
        return PendingThumbnail(
            path: thumbStoragePath(familyID: familyID, mediaID: mediaID, now: now),
            data: jpegData, pixelSize: PixelSize(width: cgImage.width, height: cgImage.height)
        )
    }

    /// 影片縮圖：取首幀（`AVAssetImageGenerator`，同 `PickedItemLoader.firstFrame` 既有作法），
    /// `maximumSize` 讓產生器直接輸出降採樣後的畫面。首幀取自「即將上傳」的那份 `fileURL`
    /// （呼叫端若先用 `VideoTrimmer` 裁切過，這裡收到的已經是裁切後的暫存檔——縮圖要反映
    /// 實際上傳的內容，不是使用者選片當下的原始檔）。生成失敗同上，回傳 `nil`。
    private static func makeVideoPendingThumbnail(
        fileURL: URL, familyID: UUID, mediaID: UUID, now: Date
    ) -> PendingThumbnail? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailMaxPixelSize, height: thumbnailMaxPixelSize)
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil),
              let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: thumbnailJPEGQuality) else {
            return nil
        }
        return PendingThumbnail(
            path: thumbStoragePath(familyID: familyID, mediaID: mediaID, now: now),
            data: jpegData, pixelSize: PixelSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

/// 讀本機暫存檔屬性失敗時的內部錯誤——不對應任何後端碼，`AppError.map` 對辨認不出來的型別
/// 一律落 `.server`（fail loud：不會有第五種「未知」分類讓呼叫端誤以為可以安全忽略）。
private enum MediaUploadFileError: Error {
    case missingFileSize
}

/// 縮圖產生完成、還沒 PUT 上去之前的暫存值——把「PUT 縮圖用的路徑＋bytes」與「寫進 media
/// 列用的 thumb_width／thumb_height」包在一起，`uploadPhoto`／`uploadVideo` 兩處都不必再
/// 各自把 thumb 路徑／寬／高拆成三個各自照顧的 optional（忘了同步更新其中一個，會讓三個
/// `thumb_*` 欄位互相對不上，撞上 `media_thumb_dimensions_consistency` CHECK）。
private struct PendingThumbnail {
    let path: String
    let data: Data
    let pixelSize: PixelSize
}

/// `insertMediaRow` 的輸入分組——把 `storagePath`／`type`／`byteSize`／`pixelSize`／`thumb`
/// 收成一個值，讓呼叫端／被呼叫端都少幾個參數（SwiftLint `function_parameter_count`）。
private struct MediaRowDescriptor {
    let storagePath: String
    let type: String
    let byteSize: Int
    let pixelSize: PixelSize
    let thumb: PendingThumbnail?
}

private struct MediaInsertPayload: Encodable {
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
    }
}

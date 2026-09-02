import Foundation
import Supabase

/// 把日記編輯器選好的一張照片／一支影片，上傳成一筆可掛在日記底下的 `media` 列。
///
/// 兩步驟（`docs/API.md` §3 `media`「上傳流程順序很重要」）：① 先把檔案 PUT 進 Storage
/// （`media` bucket，見 `supabase/migrations/20260823030000_storage_policies.sql`）② 成功後
/// 才 `insert` 對應的 `media` 列。第②步失敗時呼叫端要自己清掉①上傳的孤兒物件——兩個實作
/// 方法都遵守這個順序，並在②失敗時嘗試 `remove` 剛上傳的物件（best-effort，見實作註解）。
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
    private static let bucketID = "media"

    init(client: SupabaseClient) {
        self.client = client
    }

    func uploadPhoto(familyID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
        let mediaID = UUID()
        let path = Self.storagePath(familyID: familyID, mediaID: mediaID, fileExtension: fileExtension)
        do {
            try await client.storage.from(Self.bucketID).upload(
                path, data: data,
                options: FileOptions(contentType: Self.contentType(forExtension: fileExtension))
            )
        } catch {
            throw Self.mapUploadError(error)
        }
        do {
            try await insertMediaRow(
                id: mediaID, familyID: familyID,
                descriptor: MediaRowDescriptor(
                    storagePath: path, type: "photo", byteSize: data.count, pixelSize: pixelSize
                )
            )
        } catch {
            await Self.removeOrphan(client: client, bucketID: Self.bucketID, path: path)
            throw error
        }
        return mediaID
    }

    func uploadVideo(familyID: UUID, fileURL: URL, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
        let mediaID = UUID()
        let path = Self.storagePath(familyID: familyID, mediaID: mediaID, fileExtension: fileExtension)
        // merge-review R1 m8：讀不到檔案大小時直接 throw，不要靜默寫 0——`byte_size` 是
        // `families.storage_used_bytes` trigger 的加總來源，寫 0 等於這支影片不佔額度
        // （`init_schema.sql` 對這欄的可信度有明文要求，見協定檔對照）。
        let byteSize: Int
        do {
            byteSize = try Self.fileByteSize(at: fileURL)
        } catch {
            throw AppError.map(error)
        }
        do {
            try await client.storage.from(Self.bucketID).upload(
                path, fileURL: fileURL,
                options: FileOptions(contentType: Self.contentType(forExtension: fileExtension))
            )
        } catch {
            throw Self.mapUploadError(error)
        }
        do {
            try await insertMediaRow(
                id: mediaID, familyID: familyID,
                descriptor: MediaRowDescriptor(
                    storagePath: path, type: "video", byteSize: byteSize, pixelSize: pixelSize
                )
            )
        } catch {
            await Self.removeOrphan(client: client, bucketID: Self.bucketID, path: path)
            throw error
        }
        return mediaID
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

    /// ②失敗時清掉①已上傳的孤兒物件——best-effort：清理本身失敗不覆蓋原始錯誤（呼叫端只
    /// 在意「這次上傳失敗了」，孤兒物件清不掉是背景衛生問題，見協定檔文件註解）。
    private static func removeOrphan(client: SupabaseClient, bucketID: String, path: String) async {
        _ = try? await client.storage.from(bucketID).remove(paths: [path])
    }

    /// `{family_id}/{yyyy}/{mm}/{media_id}.{ext}`（`docs/API.md` §6）：`yyyy/mm` 取**上傳時間**
    /// （UTC，避免裝置時區造成月份邊界判斷不一致）；`family_id`／`media_id` 一律小寫正規形
    /// UUID——`UUID().uuidString` 預設大寫，這裡強制 `.lowercased()`。
    static func storagePath(familyID: UUID, mediaID: UUID, fileExtension: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month], from: Date())
        let year = String(format: "%04d", components.year ?? 1970)
        let month = String(format: "%02d", components.month ?? 1)
        let ext = fileExtension.lowercased()
        return "\(familyID.uuidString.lowercased())/\(year)/\(month)/\(mediaID.uuidString.lowercased()).\(ext)"
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
}

/// 讀本機暫存檔屬性失敗時的內部錯誤——不對應任何後端碼，`AppError.map` 對辨認不出來的型別
/// 一律落 `.server`（fail loud：不會有第五種「未知」分類讓呼叫端誤以為可以安全忽略）。
private enum MediaUploadFileError: Error {
    case missingFileSize
}

/// `insertMediaRow` 的輸入分組——把 `storagePath`／`type`／`byteSize`／`pixelSize` 收成一個
/// 值，讓呼叫端／被呼叫端都少幾個參數（SwiftLint `function_parameter_count`）。
private struct MediaRowDescriptor {
    let storagePath: String
    let type: String
    let byteSize: Int
    let pixelSize: PixelSize
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

    init(id: UUID, familyID: UUID, descriptor: MediaRowDescriptor, uploadedBy: UUID) {
        self.id = id
        self.familyID = familyID
        self.storagePath = descriptor.storagePath
        self.type = descriptor.type
        self.byteSize = descriptor.byteSize
        self.width = descriptor.pixelSize.width
        self.height = descriptor.pixelSize.height
        self.uploadedBy = uploadedBy
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
    }
}

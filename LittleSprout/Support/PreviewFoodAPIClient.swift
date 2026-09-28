#if DEBUG
import Foundation
import UIKit

/// 只給 SwiftUI `#Preview`／`TapTargetGateHarness` 用的假 `FoodAPIClient`——不打真網路（同
/// `PreviewGrowthAPIClient` 的角色）。回傳完整 274 種目錄＋呼叫端給的記錄。
///
/// LS-380：寫入（upsert／delete）與照片來源（03d）也是假的——`upsertFailure` 非 nil 時 upsert 一律丟
/// 那個錯誤（03e 儲存失敗 fixture 用）；家庭照片是啟動時畫在暫存目錄的色塊 JPEG（`file://` URL，
/// `AsyncImage` 可直接載入，不需要網路或 Storage）。
///
/// LS-380 R2：記錄是**有狀態**的——upsert／delete 會改記憶體裡那份清單，`listChildFoodRecords` 讀得到
/// 剛寫的值（同後端的自然鍵 upsert：同寶貝同食物已有一筆＝更新那一筆、保留 id），詳情頁重讀才不會倒退成舊值。
final class PreviewFoodAPIClient: FoodAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [ChildFoodRecord]
    private let upsertFailure: AppError?
    /// LS-382：非 nil 時讀取（目錄與記錄）一律丟這個錯誤——寶貝詳情入口「首次讀取失敗」fixture 用。
    private let listFailure: AppError?
    private let photos: [FamilyPhoto]
    /// 新增記錄的作者（harness 的「目前登入者」）；nil＝不填。
    private let currentUserID: UUID?

    init(
        records: [ChildFoodRecord] = [], upsertFailure: AppError? = nil, photos: [FamilyPhoto] = [],
        currentUserID: UUID? = nil, listFailure: AppError? = nil
    ) {
        self.records = records
        self.upsertFailure = upsertFailure
        self.listFailure = listFailure
        self.photos = photos
        self.currentUserID = currentUserID
    }

    func listFoodCatalog() async throws -> [FoodCatalogItem] {
        if let listFailure { throw listFailure }
        return PreviewFoodCatalog.items
    }

    func listChildFoodRecords(childID: UUID) async throws -> [ChildFoodRecord] {
        if let listFailure { throw listFailure }
        return lock.withLock { records }
    }

    func upsertChildFoodRecord(_ input: FoodRecordUpsert) async throws -> ChildFoodRecord {
        if let upsertFailure { throw upsertFailure }
        let midnight = BirthdayFormat.date(fromWireString: BirthdayFormat.wireString(from: input.firstTriedOn))!
        return lock.withLock {
            let existing = records.first { $0.childID == input.childID && $0.foodID == input.foodID }
            let saved = ChildFoodRecord(
                id: existing?.id ?? UUID(), familyID: existing?.familyID ?? UUID(), childID: input.childID,
                foodID: input.foodID, authorID: existing?.authorID ?? currentUserID, firstTriedOn: midnight,
                mediaID: input.mediaID, note: input.note, reaction: input.reaction?.rawValue,
                createdAt: existing?.createdAt ?? Date(), updatedAt: Date()
            )
            records = records.filter { $0.id != saved.id } + [saved]
            return saved
        }
    }

    func deleteChildFoodRecord(id: UUID) async throws {
        lock.withLock { records.removeAll { $0.id == id } }
    }

    func listFamilyPhotos(childID: UUID) async throws -> [FamilyPhoto] { photos }

    func fetchFamilyPhoto(id: UUID) async throws -> FamilyPhoto? { photos.first { $0.id == id } }

    /// 示範照片的 `storagePath` 本身就是暫存檔的絕對路徑。
    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] {
        Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(fileURLWithPath: $0)) })
    }

    func uploadPhoto(childID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
        UUID()
    }
}

extension FamilyPhoto {
    /// 03d 示範：記錄日期（今天）拍的 3 張＋更早的 6 張（稿 `OoYLu` 9 張不同照片、無空格）。每張是一塊
    /// 不同色相的漸層 JPEG，寫在暫存目錄（同一次啟動重複呼叫共用同一批檔案）。
    static func previewSamples(now: Date = Date()) -> [FamilyPhoto] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LS-380-preview-photos")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hues: [CGFloat] = [0.02, 0.08, 0.13, 0.33, 0.45, 0.55, 0.62, 0.75, 0.9]
        return hues.enumerated().map { index, hue in
            let url = directory.appendingPathComponent("photo-4x3-\(index).jpg")
            if !FileManager.default.fileExists(atPath: url.path) {
                try? samplePhotoData(hue: hue).write(to: url)
            }
            let takenAt = index < 3
                ? now.addingTimeInterval(-Double(index + 1) * 600)
                : now.addingTimeInterval(-Double(index) * 86_400 * 3)
            return FamilyPhoto(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                storagePath: url.path, thumbPath: nil, takenAt: takenAt, createdAt: takenAt
            )
        }
    }

    /// 橫幅（4:3）——真實照片多半不是正方形，用正方形示範圖會遮住「縮圖撐出欄外」這類版面問題。
    private static func samplePhotoData(hue: CGFloat) -> Data {
        let size = CGSize(width: 320, height: 240)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [
                UIColor(hue: hue, saturation: 0.35, brightness: 0.95, alpha: 1).cgColor,
                UIColor(hue: hue, saturation: 0.6, brightness: 0.7, alpha: 1).cgColor
            ] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: []
            )
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
}

extension FoodBookStore {
    /// LS-326 Notes `UsJkk` 示範資料集：陳小安（出生 2025-04-20，「今天」2026-08-20），已吃 38／274——
    /// 穀物根莖 10／16（品項與日期逐格照稿 `hWu6N`）、乳製品 1／7（優格 2026/5/2，照稿 `SYefI`）、
    /// 蔬菜 12、水果 9、肉魚蛋豆 5、台灣家常 1（稿面沒逐格畫，取該類 `sort_order` 前 N 樣、日期示意）。
    @MainActor
    static func previewSeededWithDemoRecords(
        childID: UUID = UUID(), apiClient: FoodAPIClient = PreviewFoodAPIClient()
    ) -> FoodBookStore {
        let store = FoodBookStore(childID: childID, apiClient: apiClient)
        store.seedForPreview(catalog: PreviewFoodCatalog.items, records: demoRecords(childID: childID))
        return store
    }

    static func demoRecords(childID: UUID) -> [ChildFoodRecord] {
        let familyID = UUID()
        func record(_ foodID: String, _ day: String) -> ChildFoodRecord {
            let date = BirthdayFormat.date(fromWireString: day)!
            return ChildFoodRecord(
                id: UUID(), familyID: familyID, childID: childID, foodID: foodID, authorID: nil, firstTriedOn: date,
                mediaID: nil, note: nil, reaction: nil, createdAt: date, updatedAt: date
            )
        }
        let pinned: [(String, String)] = [
            ("rice_cereal", "2025-10-22"), ("rice_porridge", "2025-11-03"), ("oatmeal", "2026-01-05"),
            ("white_rice", "2026-02-14"), ("sweet_potato", "2025-11-10"), ("potato", "2025-12-01"),
            ("pumpkin", "2025-11-18"), ("corn", "2026-03-02"), ("noodles", "2026-04-11"), ("bread", "2026-06-08"),
            ("yogurt", "2026-05-02")
        ]
        let filler: [(FoodCategory, Int)] = [(.vegetable, 12), (.fruit, 9), (.protein, 5), (.twHome, 1)]
        let fillerIDs = filler.flatMap { category, count in
            PreviewFoodCatalog.items.filter { $0.category == category }.prefix(count).map(\.id)
        }
        return pinned.map { record($0.0, $0.1) } + fillerIDs.map { record($0, "2026-07-15") }
    }
}
#endif

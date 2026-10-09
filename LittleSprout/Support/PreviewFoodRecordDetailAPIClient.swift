#if DEBUG
import UIKit

/// 只給 `#Preview`／`TapTargetGateHarness` 用的假 `FoodRecordDetailAPIClient`——不打真網路。照片回一個本機
/// 檔案 URL（把 bundle 內 `HeroGrandma` 寫進暫存資料夾一次），讓 `AsyncImage` 走跟正式簽名 URL 同一條路徑；
/// 稿面示範照本來就是佔位（Notes `jQp2m`「示範照為佔位，實作以家庭照片為準」）。
final class PreviewFoodRecordDetailAPIClient: FoodRecordDetailAPIClient, @unchecked Sendable {
    private let names: [UUID: String]
    /// false＝簽名網址一律拿不到（04e 照片載入失敗 fixture）。
    private let photoAvailable: Bool

    init(names: [UUID: String], photoAvailable: Bool = true) {
        self.names = names
        self.photoAvailable = photoAvailable
    }

    func photoURL(mediaID: UUID) async throws -> URL? {
        photoAvailable ? Self.samplePhotoURL : nil
    }

    func displayName(userID: UUID) async throws -> String? {
        names[userID]
    }

    /// LS-383：時間軸食物卡 harness（`TapTargetGateHarness+FoodFirstCard.swift`）共用同一張佔位照。
    static let samplePhotoURL: URL? = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LS-381-preview-photo.jpg")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = UIImage(named: "HeroGrandma")?.jpegData(compressionQuality: 0.8),
              (try? data.write(to: url)) != nil else { return nil }
        return url
    }()
}
#endif

#if DEBUG
import UIKit

/// 只給 `#Preview`／`TapTargetGateHarness` 用的假 `FoodRecordDetailAPIClient`——不打真網路。照片回一個本機
/// 檔案 URL（把 bundle 內 `HeroGrandma` 寫進暫存資料夾一次），讓 `AsyncImage` 走跟正式簽名 URL 同一條路徑；
/// 稿面示範照本來就是佔位（Notes `jQp2m`「示範照為佔位，實作以家庭照片為準」）。
final class PreviewFoodRecordDetailAPIClient: FoodRecordDetailAPIClient, @unchecked Sendable {
    private let names: [UUID: String]
    /// true＝「第一輪載入」的簽名網址拿不到（回 nil），按「再試一次」之後才成功——04e 照片載入失敗 fixture。
    /// 「一輪」＝彼此相隔不到 `burstGap` 的連續請求：詳情頁開啟時 `.task` 可能連發兩次（取消重啟），用固定次數
    /// 數會因時序而飄；重試是使用者按下之後才發的新一輪，間隔遠大於 `burstGap`。
    private let failsFirstLoad: Bool
    private let lock = NSLock()
    private var lastRequestAt: Date?
    private var firstLoadOver = false
    private static let burstGap: TimeInterval = 0.5

    init(names: [UUID: String], failsFirstLoad: Bool = false) {
        self.names = names
        self.failsFirstLoad = failsFirstLoad
    }

    func photoURL(mediaID: UUID) async throws -> URL? {
        let fails = lock.withLock { () -> Bool in
            let now = Date()
            defer { lastRequestAt = now }
            if let lastRequestAt, now.timeIntervalSince(lastRequestAt) > Self.burstGap { firstLoadOver = true }
            return failsFirstLoad && !firstLoadOver
        }
        return fails ? nil : Self.samplePhotoURL
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

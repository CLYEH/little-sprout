import Photos
import SwiftUI

/// 群卡縮圖真實載入（LS-303 R2，merge-review R1 M1）——依 `PHAsset.localIdentifier` 查
/// `PHAsset`、用 `PHCachingImageManager.requestImage` 要縮圖。`assetsByID` 在
/// `PhotoLibraryAccessService.pickedAssetsResult(for:)` 分組當下一併建好（同一次
/// `PHAsset.fetchAssets` 查詢結果，見該檔文件註解），本型別只負責「拿 id 換圖」，不重新
/// 查詢 Photos 資料庫。
///
/// `@MainActor`：`PHCachingImageManager` 的 completion handler 不保證在哪個 queue 呼叫
/// （Apple 文件：`resultHandler` 可能在背景 queue），`requestImage` 內部用 `Task { @MainActor
/// in }` 把回呼跳回主執行緒才叫呼叫端的 `completion`，呼叫端因此不需要自己再包一層。
@MainActor
final class ImportThumbnailProvider {
    private let assetsByID: [String: PHAsset]
    private let imageManager = PHCachingImageManager()

    init(assetsByID: [String: PHAsset]) {
        self.assetsByID = assetsByID
    }

    /// 找不到（`.limited` 授權範圍外或 harness／preview 的假 id）時直接回呼 `nil`，呼叫端
    /// 退回系統圖示佔位（`ImportThumbnailCell` 既有寫法），不是錯誤態。
    @discardableResult
    func requestImage(
        for id: String, targetSize: CGSize, completion: @escaping @MainActor (UIImage?) -> Void
    ) -> PHImageRequestID? {
        guard let asset = assetsByID[id] else {
            completion(nil)
            return nil
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return imageManager.requestImage(
            for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options
        ) { image, _ in
            Task { @MainActor in completion(image) }
        }
    }

    func cancelRequest(_ id: PHImageRequestID) {
        imageManager.cancelImageRequest(id)
    }
}

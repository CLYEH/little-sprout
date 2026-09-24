import UIKit

/// 飲食圖鑑貼紙（`design/food-stickers/stickers/<food_id>.png`，274 張 384×384 RGBA）的載入與快取。
///
/// **資產放法**（LS-379 決定，見 handoff）：`project.yml` 把 `design/food-stickers/stickers` 整個資料夾
/// 以 folder reference 放進 app bundle（folder reference 沿用原資料夾名，bundle 內路徑＝
/// `stickers/<id>.png`），不另外複製一份進 `Assets.xcassets`——repo 內只有 `design/` 這一份原檔（裁切腳本的唯一
/// 輸出位置），不會兩邊漂移。
///
/// **解碼離開主執行緒**（merge-review R2.4）：`UIImage(contentsOfFile:)` 只讀檔頭，真正的解碼會拖到
/// 第一次繪製、落在主執行緒；這裡在呼叫端的 `.task` 裡（非主執行緒的 async 函式）先解碼好再交回畫面，
/// 捲動蔬菜類（91 格）時不會在主執行緒逐格解碼。
///
/// **記憶體有上限**（LS-379 R2，merge-review R1 M1：原本 384² 原尺寸解碼、`NSCache` 無上限，8 類捲到底
/// 常駐多約 182MB）：
/// - 依顯示尺寸解碼（`byPreparingThumbnail(ofSize:)`，呼叫端傳 `點數 × displayScale`）：格子 80pt@3x＝240px，
///   一張 225KB，是原尺寸 576KB 的 0.4 倍。
/// - 快取以 bytes 計 cost、`totalCostLimit`＝`cacheCostLimit`（24MB）：約 100 張 240px 格子，放得下最大的
///   蔬菜類（91 格）一整類，換類後舊的依 LRU 被擠掉，不會隨逛過的類別累積。
/// 快取鍵含像素尺寸——同一張貼紙在格子（80pt）與 AX 清單／佔位頁（96pt）是兩個不同尺寸的解碼結果。
final class FoodStickerLoader: @unchecked Sendable {
    static let shared = FoodStickerLoader()

    /// bundle 內的資料夾名——與 `project.yml` 的 folder reference 目的地一致（`FoodStickerAssetsTests`
    /// 以 274 張全數可讀鎖住兩邊）。
    static let bundleSubdirectory = "stickers"

    /// 快取上限（bytes）。見型別文件註解；`FoodStickerAssetsTests.test_cacheHasByteCostLimit` 鎖住。
    static let cacheCostLimit = 24 * 1024 * 1024

    private let cache = NSCache<NSString, UIImage>()
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        cache.totalCostLimit = Self.cacheCostLimit
    }

    /// 目前生效的快取上限——只給測試讀。
    var cacheTotalCostLimit: Int { cache.totalCostLimit }

    func url(for foodID: String) -> URL? {
        bundle.url(forResource: foodID, withExtension: "png", subdirectory: Self.bundleSubdirectory)
    }

    /// 已解碼且在快取裡的圖——同步路徑，讓已看過的格子第一幀就有圖，不閃一下空白。
    func cachedImage(for foodID: String, pixelSize: Int) -> UIImage? {
        cache.object(forKey: Self.cacheKey(foodID, pixelSize))
    }

    /// 讀檔＋依 `pixelSize`（邊長像素，不放大超過原圖）解碼（非主執行緒）；找不到檔案回 nil（格子留白，
    /// 不崩潰——274 張與 catalog 一一對應由 `FoodStickerAssetsTests` 把關）。
    func image(for foodID: String, pixelSize: Int) async -> UIImage? {
        if let cached = cachedImage(for: foodID, pixelSize: pixelSize) { return cached }
        guard let url = url(for: foodID), let raw = UIImage(contentsOfFile: url.path) else { return nil }
        let rawPixels = Int(raw.size.width * raw.scale)
        let target = CGFloat(min(max(pixelSize, 1), rawPixels))
        let decoded = await raw.byPreparingThumbnail(ofSize: CGSize(width: target, height: target)) ?? raw
        cache.setObject(decoded, forKey: Self.cacheKey(foodID, pixelSize), cost: Self.byteCost(of: decoded))
        return decoded
    }

    /// 解碼後點陣圖佔的 bytes（`bytesPerRow × height`），當 `NSCache` 的 cost。
    static func byteCost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage { return cgImage.bytesPerRow * cgImage.height }
        return Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    private static func cacheKey(_ foodID: String, _ pixelSize: Int) -> NSString {
        "\(foodID)@\(pixelSize)" as NSString
    }
}

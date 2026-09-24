import UIKit

/// 飲食圖鑑貼紙（`design/food-stickers/stickers/<food_id>.png`，274 張 384×384 RGBA）的載入與快取。
///
/// **資產放法**（LS-379 決定，見 handoff）：`project.yml` 把 `design/food-stickers/stickers` 整個資料夾
/// 以 folder reference 放進 app bundle（folder reference 沿用原資料夾名，bundle 內路徑＝
/// `stickers/<id>.png`），不另外複製一份進 `Assets.xcassets`——repo 內只有 `design/` 這一份原檔（裁切腳本的唯一
/// 輸出位置），不會兩邊漂移。
///
/// **解碼離開主執行緒**（merge-review R2.4）：`UIImage(contentsOfFile:)` 只讀檔頭，真正的解碼會拖到
/// 第一次繪製、落在主執行緒；這裡在呼叫端的 `.task` 裡（非主執行緒的 async 函式）先
/// `byPreparingForDisplay()` 解碼好再交回畫面，捲動蔬菜類（91 格）時不會在主執行緒逐格解碼。
/// 解碼後的點陣圖放進 `NSCache`（執行緒安全；記憶體壓力下系統自動清），換分頁再切回來不重讀檔。
final class FoodStickerLoader: @unchecked Sendable {
    static let shared = FoodStickerLoader()

    /// bundle 內的資料夾名——與 `project.yml` 的 folder reference 目的地一致（`FoodStickerLoaderTests`
    /// 以 274 張全數可讀鎖住兩邊）。
    static let bundleSubdirectory = "stickers"

    private let cache = NSCache<NSString, UIImage>()
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func url(for foodID: String) -> URL? {
        bundle.url(forResource: foodID, withExtension: "png", subdirectory: Self.bundleSubdirectory)
    }

    /// 已解碼且在快取裡的圖——同步路徑，讓已看過的格子第一幀就有圖，不閃一下空白。
    func cachedImage(for foodID: String) -> UIImage? {
        cache.object(forKey: foodID as NSString)
    }

    /// 讀檔＋解碼（非主執行緒）；找不到檔案回 nil（格子留白，不崩潰——274 張與 catalog 一一對應
    /// 由 `design/food-stickers/README.md` 的一致性檢查與 `FoodStickerLoaderTests` 把關）。
    func image(for foodID: String) async -> UIImage? {
        if let cached = cachedImage(for: foodID) { return cached }
        guard let url = url(for: foodID), let raw = UIImage(contentsOfFile: url.path) else { return nil }
        let decoded = await raw.byPreparingForDisplay() ?? raw
        cache.setObject(decoded, forKey: foodID as NSString)
        return decoded
    }
}

import Foundation
@testable import LittleSprout
import XCTest

/// LS-379：貼紙資產進 bundle 的方式（`project.yml` folder reference → `stickers/<food_id>.png`）與 DEBUG
/// 示範目錄（`PreviewFoodCatalog`）的一致性。
///
/// - 274 張全部讀得到：少一張，那一格就是空白方塊；folder reference 路徑改了（或 `xcodegen generate`
///   沒重跑）會整批讀不到。
/// - `PreviewFoodCatalog` 逐列等於 `supabase/seed-data/food_catalog.csv`：harness 截圖對稿用的是這份複本，
///   CSV 改了複本沒跟上，截圖就會跟正式資料不一樣。
final class FoodStickerAssetsTests: XCTestCase {
    func test_everyCatalogFoodHasStickerInAppBundle() {
        let loader = FoodStickerLoader(bundle: Bundle(for: FoodStickerLoader.self))
        let missing = PreviewFoodCatalog.items.map(\.id).filter { loader.url(for: $0) == nil }
        XCTAssertEqual(PreviewFoodCatalog.items.count, 274)
        XCTAssertEqual(missing, [], "bundle 內缺這些貼紙（folder reference 或 xcodegen 沒跟上？）")
    }

    func test_bundleHasNoExtraStickers() throws {
        let bundle = Bundle(for: FoodStickerLoader.self)
        let urls = bundle.urls(
            forResourcesWithExtension: "png", subdirectory: FoodStickerLoader.bundleSubdirectory
        ) ?? []
        let bundledIDs = Set(urls.map { $0.deletingPathExtension().lastPathComponent })
        XCTAssertEqual(bundledIDs, Set(PreviewFoodCatalog.items.map(\.id)))
    }

    /// LS-379 R2（merge-review R1 M1）：依顯示尺寸解碼——格子 80pt@3x 只該解成 240px，不是原圖 384px
    /// （原尺寸 576KB／張，274 張逛完常駐約 158MB）；要求比原圖大時不放大。
    func test_stickerDecodesAtRequestedPixelSizeNotOriginal() async throws {
        let loader = FoodStickerLoader(bundle: Bundle(for: FoodStickerLoader.self))
        let image = await loader.image(for: "pumpkin", pixelSize: 240)
        let decoded = try XCTUnwrap(image, "pumpkin.png 應該讀得到並解碼")
        XCTAssertEqual(decoded.size.width * decoded.scale, 240, accuracy: 1)
        XCTAssertEqual(decoded.size.height * decoded.scale, 240, accuracy: 1)
        XCTAssertLessThanOrEqual(FoodStickerLoader.byteCost(of: decoded), 240 * 240 * 4 + 240 * 64)
        XCTAssertNotNil(loader.cachedImage(for: "pumpkin", pixelSize: 240), "解碼後要進快取，換分頁回來不重讀檔")
        XCTAssertNil(loader.cachedImage(for: "pumpkin", pixelSize: 288), "不同像素尺寸是不同快取項")

        let oversized = await loader.image(for: "pumpkin", pixelSize: 1000)
        let big = try XCTUnwrap(oversized)
        XCTAssertEqual(big.size.width * big.scale, 384, accuracy: 1, "不放大超過原圖")
        let unknown = await loader.image(for: "no_such_food", pixelSize: 240)
        XCTAssertNil(unknown)
    }

    /// LS-379 R2（merge-review R1 M1）：快取必須有以 bytes 計的上限，且上限要小到不會把整本 274 張
    /// 都留著（240px 一張 225KB，274 張約 62MB），又大到放得下最大的一類（蔬菜 91 格）。拿掉
    /// `totalCostLimit` 這個測試會紅。
    func test_cacheHasByteCostLimit() {
        let loader = FoodStickerLoader(bundle: Bundle(for: FoodStickerLoader.self))
        let perGridSticker = 240 * 240 * 4
        XCTAssertEqual(loader.cacheTotalCostLimit, FoodStickerLoader.cacheCostLimit)
        XCTAssertGreaterThan(loader.cacheTotalCostLimit, 0, "0＝NSCache 無上限")
        XCTAssertGreaterThanOrEqual(loader.cacheTotalCostLimit, 91 * perGridSticker, "要放得下蔬菜類一整類")
        XCTAssertLessThan(loader.cacheTotalCostLimit, 274 * perGridSticker, "不能大到整本都常駐")
    }

    func test_previewCatalogMatchesSeedCSVRowByRow() throws {
        let csvURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("supabase/seed-data/food_catalog.csv")
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        let rows = csv.split(whereSeparator: \.isNewline).dropFirst().map(String.init)
        XCTAssertEqual(PreviewFoodCatalog.csvRows, rows, "PreviewFoodCatalog.swift 要由 CSV 重新產生")
    }
}

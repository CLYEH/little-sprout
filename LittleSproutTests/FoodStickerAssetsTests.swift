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

    func test_stickerDecodesAt384Square() async throws {
        let loader = FoodStickerLoader(bundle: Bundle(for: FoodStickerLoader.self))
        let image = await loader.image(for: "pumpkin")
        let decoded = try XCTUnwrap(image, "pumpkin.png 應該讀得到並解碼")
        XCTAssertEqual(decoded.size.width * decoded.scale, 384)
        XCTAssertEqual(decoded.size.height * decoded.scale, 384)
        XCTAssertNotNil(loader.cachedImage(for: "pumpkin"), "解碼後要進快取，換分頁回來不重讀檔")
        let unknown = await loader.image(for: "no_such_food")
        XCTAssertNil(unknown)
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

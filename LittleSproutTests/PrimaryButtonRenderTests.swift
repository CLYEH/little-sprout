@testable import LittleSprout
import SwiftUI
import XCTest

/// LS-445（LS-442 C1a／C2a）：`PrimaryButton` 對稿——稿 `OKSJI` 高 60、字重 700。
///
/// 實作原本由 `controlPaddingCTA` 17.5×2＋22pt icon 框推導只有 57pt，主鈕文字也沒給字重（比
/// `SecondaryButton` 的 `.lead medium` 還輕）。這裡用 `ImageRenderer` 實際渲染，量**畫出來**的
/// 高度與字重，而不是只斷言常數——常數（`PrimaryButton.minHeight`／`labelWeight`）被 body 漏接
/// 時，常數斷言量不到，渲染量得到。
@MainActor
final class PrimaryButtonRenderTests: XCTestCase {
    private static let renderScale: CGFloat = 3
    private static let width: CGFloat = 390

    // MARK: - 高度（C1a）

    /// 預設字級：內容 22 → padding 推導 57，`minHeight` 60 下限補到 60。
    func test_defaultSize_rendersAtDesignHeight60() throws {
        let height = try renderedHeight(.large)
        XCTAssertEqual(
            height, 60, accuracy: 0.5,
            "主鈕預設字級應渲染成稿面 h=60（OKSJI，LS-442 C1a）；實測 \(height)pt——"
                + "沒有 minHeight 下限時是 padding 推導的 57pt"
        )
    }

    /// AX3：下限不得變成固定高——內容與 padding 自己長高（稿面 AX3 變體約 83；容許更高，不容許被壓回 60）。
    func test_accessibility3_stillGrowsPastFloor() throws {
        let height = try renderedHeight(.accessibility3)
        XCTAssertGreaterThanOrEqual(
            height, 83,
            "AX3 主鈕應由 padding／內容撐到 ≥83（LS-442 C1a：下限不是固定高）；實測 \(height)pt"
        )
    }

    // MARK: - 字重（C2a）

    /// 主鈕文字要渲染成 bold（稿 700）：墨量與同字級 bold 參考文字一致，且明顯多於 semibold／regular。
    /// 墨量＝每像素與底色亮度差的總和；字重越重筆畫越粗、總量越大，與字形位置的次像素偏移無關。
    func test_label_rendersBold() throws {
        let primary = try inkOfPrimaryButton()
        let bold = try inkOfReferenceLabel(weight: .bold)
        let semibold = try inkOfReferenceLabel(weight: .semibold)
        let regular = try inkOfReferenceLabel(weight: .regular)

        XCTAssertEqual(
            primary / bold, 1, accuracy: 0.03,
            "主鈕文字墨量應等同 bold 參考（比值 \(primary / bold)；semibold／bold＝\(semibold / bold)，"
                + "regular／bold＝\(regular / bold)）——字重沒套上 bold（LS-442 C2a）"
        )
        XCTAssertGreaterThan(
            primary / semibold, 1.03,
            "主鈕文字應比 semibold 重（比值 \(primary / semibold)）：稿 700，不是 600"
        )
    }

    /// 常數與渲染同源：`labelWeight` 是 `.bold`（iPad 行內鈕 `addPhotosInlineButton` 不吃字重，只吃 `minHeight`）。
    func test_constants_matchDesign() {
        XCTAssertEqual(PrimaryButton.minHeight, 60)
        XCTAssertEqual(PrimaryButton.labelWeight, .bold)
    }

    // MARK: - 渲染

    private func renderedHeight(_ size: DynamicTypeSize) throws -> CGFloat {
        let content = PrimaryButton(icon: "paperplane", title: "寄送驗證碼", action: {})
            .frame(width: Self.width)
            .environment(\.dynamicTypeSize, size)
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.renderScale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer 沒有產出影像")
        return CGFloat(image.height) / Self.renderScale
    }

    private func inkOfPrimaryButton() throws -> Double {
        // 無 icon：墨量只來自文字。固定 60 高讓兩邊影像尺寸一致。
        try ink(of: PrimaryButton(icon: nil, title: "加入照片", action: {}))
    }

    private func inkOfReferenceLabel(weight: Font.Weight) throws -> Double {
        try ink(of: Text("加入照片")
            .appFont(.body, weight: weight)
            .foregroundStyle(Color.lsOnAccent)
            .frame(maxWidth: .infinity))
    }

    private func ink(of view: some View) throws -> Double {
        let content = view
            .frame(width: Self.width, height: PrimaryButton.minHeight)
            // 圓角外的透明像素也墊 accent，兩邊底色一致（取樣點 (1,1) 落在按鈕圓角外）。
            .background(Color.lsAccent)
            .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.renderScale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer 沒有產出影像")
        let pixels = try SRGBPixels(image)
        let background = pixels.luminance(column: 1, row: 1)
        var total = 0.0
        for row in 0..<pixels.height {
            for column in 0..<pixels.width {
                total += abs(pixels.luminance(column: column, row: row) - background)
            }
        }
        return total
    }
}

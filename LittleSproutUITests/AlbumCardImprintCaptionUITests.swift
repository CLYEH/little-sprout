import UIKit
import XCTest

/// LS-390：時間軸相簿卡（`AlbumCardView`，稿 `cmp/Card Album` `bhroo`／Imprint Row `IXmLN`）標題進白邊。
///
/// 淺深 × xSmall／預設／AX3：Caption「相簿名 · N 張相片」用印品墨色畫在紙上、字起點落在紙左緣 20
/// （printEdge 8＋sp-group 12＝日記卡 `$inset-card`，同軸）、整張卡本體是**一個** VoiceOver 元素且含張數。
/// 改前標題畫在頁面底色（字起點 25、字色 `lsTextPrimary`）。像素量法沿用 `PhotoCardBabyCaptionUITests`
/// 的 `InkRaster`（墨色＝低亮度且帶紅相，排除深色染料池的中性暗角）。
@MainActor
final class AlbumCardImprintCaptionUITests: XCTestCase {
    private static let xSmall = "UICTContentSizeCategoryXS"
    private static let large = "UICTContentSizeCategoryL"
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"
    /// `PrintPhotoCard` 染料池圓半徑（`cornerSize` 26 × 6 ÷ 2），見 `captionRaster` 註解。
    private static let glowRadius: CGFloat = 78
    private static let shortLabel = "弟弟出生的第一週，8 張相片"
    private static let longLabel = "阿公阿嬤全家福二〇二六跨年夜溫馨團聚倒數紀念相片珍藏加長版本紀念冊，1 張相片"

    func testTimelineAlbumCard_captionOnImprintAxis_lightDark_xSmallDefaultAX3() throws {
        for scheme in ["light", "dark"] {
            for size in [Self.xSmall, Self.large, Self.ax3] {
                let context = "\(scheme)/\(size)"
                let app = launch(fixture: "timelineAlbum", size: size, scheme: scheme)
                let paper = paperElement(in: app, label: Self.shortLabel)
                XCTAssertEqual(
                    app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", Self.shortLabel)).count,
                    1, "[\(context)] 相簿卡本體應念成一個元素且含張數（標題不重複念）"
                )
                let raster = try captionRaster(paper: paper, in: app, context: context)
                let startX = 15 + (try XCTUnwrap(raster.leftmostInkX, "[\(context)] Caption 區沒有墨色字形"))
                XCTAssertGreaterThanOrEqual(
                    startX, 19.5, "[\(context)] Caption 字起點離紙左緣 \(startX)pt，應 ≈ 20（與日記卡同軸）"
                )
                XCTAssertLessThan(startX, 23.5, "[\(context)] Caption 字起點離紙左緣 \(startX)pt，偏離 20 太多")
                let lines = raster.lines()
                print("LS-390 captionStartX \(context)=\(startX) lines=\(lines.count)")
                if size == Self.ax3 {
                    XCTAssertGreaterThanOrEqual(
                        lines.count, 2, "[\(context)] AX3 相簿名與張數各自成行、不截斷，量到 \(lines.count) 行"
                    )
                } else {
                    XCTAssertEqual(
                        lines.count, 1, "[\(context)] Caption 應單行「相簿名 · 8 張相片」，量到 \(lines.count) 行"
                    )
                }
                attachScreenshot(app, name: "timelineAlbum-\(scheme)-\(size)")
                app.terminate()
            }
        }
    }

    /// 稿面 `Stress / 14`：超長相簿名＋單張相片——AX3 也不截斷（至少三行）。
    func testTimelineAlbumCard_longTitle_ax3_wrapsWithoutTruncation() throws {
        let app = launch(fixture: "timelineAlbumLong", size: Self.ax3, scheme: "light")
        let paper = paperElement(in: app, label: Self.longLabel)
        let lines = try captionRaster(paper: paper, in: app, context: "long/AX3").lines()
        attachScreenshot(app, name: "timelineAlbumLong-AX3")
        XCTAssertGreaterThanOrEqual(lines.count, 3, "超長相簿名 AX3 應多行換行不截斷，量到 \(lines.count) 行")
    }

    /// LS-406（LS-390 R1 I1）：整張相簿卡念成一個元素（`.ignore`）後，封面照片的 `.isImage` trait 要補回來——
    /// VoiceOver 念「圖像」。`isImage` 在 XCUI 對應 `elementType == .image`。有封面才有、占位圖（`cover: nil`）不加。
    func testTimelineAlbumCard_isImageTrait_onlyWhenCoverPresent() {
        let withCover = launch(fixture: "timelineAlbumCover", size: Self.large, scheme: "light")
        let coverCard = paperElement(in: withCover, label: Self.shortLabel)
        XCTAssertEqual(
            coverCard.elementType, .image,
            "封面已載入的相簿卡應帶 .isImage trait（VoiceOver 念「圖像」），實際 elementType＝\(coverCard.elementType.rawValue)"
        )
        withCover.terminate()
        let placeholder = launch(fixture: "timelineAlbum", size: Self.large, scheme: "light")
        let placeholderCard = paperElement(in: placeholder, label: Self.shortLabel)
        XCTAssertNotEqual(
            placeholderCard.elementType, .image,
            "占位圖（沒有封面）的相簿卡不該帶 .isImage trait（念「圖像」會誤導）"
        )
    }

    // MARK: - helpers

    private func launch(fixture: String, size: String, scheme: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = TapTargetGateScreenName.photoCardBabyCaption.rawValue
        app.launchEnvironment["LS_PHOTO_CARD_CAPTION_FIXTURE"] = fixture
        app.launchEnvironment["LS_PHOTO_CARD_CAPTION_SCHEME"] = scheme
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        app.launch()
        return app
    }

    private func paperElement(in app: XCUIApplication, label: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "時間軸相簿卡（label「\(label)」）沒渲染")
        return element
    }

    /// 裁出 Caption 區：照片（printEdge 8＋190）下 7 起、扣底部 printEdgeBottom 8；左緣取 15（避開角托）、
    /// 右緣對稱。回傳的 raster 以裁切左緣為 x=0（`leftmostInkX` 需再加 15）。
    private func captionRaster(paper: XCUIElement, in app: XCUIApplication, context: String) throws -> InkRaster {
        // 卡片元素的 a11y frame 會把染料池圓（`PrintPhotoCard.mountPoolGlow`，直徑＝角托 26×6，圓心在四角）
        // 一起算進去，四邊各外擴半徑 78——實測 XS 為 (-54, 30, 510×387)，扣回來才是紙（左緣＝screenPad 24）。
        let frame = paper.frame.insetBy(dx: Self.glowRadius, dy: Self.glowRadius)
        let area = CGRect(x: frame.minX + 15, y: frame.minY + 205, width: frame.width - 30, height: frame.height - 213)
        let screenshot = app.screenshot().image
        let cgImage = try XCTUnwrap(screenshot.cgImage, "[\(context)] 截圖沒有 cgImage")
        return try XCTUnwrap(
            InkRaster(cgImage: cgImage, scale: screenshot.scale, rect: area), "[\(context)] 裁切 Caption 範圍失敗"
        )
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "LS-390-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

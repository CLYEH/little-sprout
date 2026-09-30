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
                if size == Self.ax3 {
                    XCTAssertGreaterThanOrEqual(
                        lines.count, 2, "[\(context)] AX3 單行公式折行（相簿名放不下時折行）、不截斷，量到 \(lines.count) 行"
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

    /// LS-406 R2 M1：定案稿 Notes `E2AtB`——時間軸板（含 AX3 的 `lKoZG`／`aGkJ1`，實例 `uvL4p`／`jGudh`）的相簿卡
    /// 用單行公式「相簿名 · N 張相片」、AX3 也**不**拆成「相簿名＼\n張數」兩行（兩行版式只給相簿頁卡）。
    /// 超長標題（`Stress / 14`）AX3 折成 5 行，末行「冊」與「· 1 張相片」同行＝5 行；`\n` 版把張數獨立成行＝6 行。
    /// 用超長標題而非短標題：短標題 AX3 本來就放得下一行，`\n` 與單行公式都量到 2 行、分不出來。
    func testTimelineAlbumCard_ax3_usesSingleLineFormula_countSharesLastTitleLine() throws {
        let app = launch(fixture: "timelineAlbumLong", size: Self.ax3, scheme: "light")
        let paper = paperElement(in: app, label: Self.longLabel)
        let lines = try captionRaster(paper: paper, in: app, context: "single-line/AX3").lines()
        attachScreenshot(app, name: "timelineAlbumLong-singleLineFormula-AX3")
        XCTAssertEqual(
            lines.count, 5,
            "AX3 時間軸相簿卡應用單行公式（末行「冊」與「· 1 張相片」同行，共 5 行）；量到 \(lines.count) 行——"
                + "6 行代表仍用換行把張數獨立成行（稿 Notes E2AtB：兩行版式只給相簿頁卡）"
        )
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

    /// LS-407 範圍 2（池 1d1587a7）：真的時間軸（`TimelineView`）內，有封面與占位圖兩張相簿卡的 a11y frame 都該是**紙面**
    /// 且彼此一致（差 ≤1pt）。改前：染料池圓把 frame 撐成 510×389（x=-54）；扣掉染料池後封面影像又撐成 380（x=11）、
    /// 占位圖被角托撐成 365（x=18.5）——QA 讀到的 380 vs 338 同型。紙面寬＝視窗寬扣兩側 `$screen-pad` 24。
    func testFeedAlbumCards_a11yFrame_isPaper_sameForCoverAndPlaceholder() {
        let app = launch(fixture: "feedAlbums", size: Self.large, scheme: "light")
        let cover = paperElement(in: app, label: "阿公阿嬤家過年，8 張相片").frame
        let placeholder = paperElement(in: app, label: "占位圖相簿，3 張相片").frame
        let paperWidth = app.windows.firstMatch.frame.width - 2 * 24
        for (name, frame) in [("封面", cover), ("占位圖", placeholder)] {
            XCTAssertEqual(
                frame.width, paperWidth, accuracy: 1,
                "[\(name)] a11y frame 寬 \(frame.width) 應＝紙面寬 \(paperWidth)（\(frame)）"
            )
            XCTAssertEqual(
                frame.minX, 24, accuracy: 1, "[\(name)] a11y frame 左緣 \(frame.minX) 應＝紙左緣 24（\(frame)）"
            )
        }
        XCTAssertEqual(
            cover.width, placeholder.width, accuracy: 1,
            "封面 \(cover.width) vs 占位圖 \(placeholder.width) 兩卡 a11y frame 寬應一致"
        )
        XCTAssertEqual(
            cover.minX, placeholder.minX, accuracy: 1,
            "封面 \(cover.minX) vs 占位圖 \(placeholder.minX) 兩卡 a11y frame 左緣應一致"
        )
    }

    /// LS-407 範圍 1（池 82a6799d）＋R2 M1：相簿 tab 首頁（真 `AlbumsView`，`AlbumsViewPopulatedState` fixture）每張卡是一顆
    /// `NavigationLink` button，VoiceOver 焦點落在 button——`.isImage` 要在 button 上才念得到（內層 `.combine` 的 trait 被吞）。
    /// 首本相簿有封面、其餘占位圖：有封面的 button 帶 image bit、占位圖的不帶。XCUI 的 `elementType` 讀不出 trait，
    /// 直接讀 accessibility traits 位元（`UIAccessibilityTraits.image`＝0x4）。
    func testAlbumsTabCards_isImageTrait_onlyWhenCoverPresent() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = TapTargetGateScreenName.albumsPopulatedState.rawValue
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", Self.large]
        app.launch()
        let coverTraits = try cardButtonTraits(in: app, title: "上禮拜的動物園一日遊")
        XCTAssertTrue(
            coverTraits.contains(.image),
            "有封面的相簿卡 button 應帶 .isImage trait（VoiceOver 念「圖像」），實際 traits＝\(coverTraits.rawValue)"
        )
        let placeholderTraits = try cardButtonTraits(in: app, title: "跨年連假出遊")
        XCTAssertFalse(
            placeholderTraits.contains(.image),
            "占位圖（沒有封面）的相簿卡 button 不該帶 .isImage trait（念「圖像」會誤導），實際 traits＝\(placeholderTraits.rawValue)"
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

    /// 相簿卡 `NavigationLink` button（label 含相簿名）的 accessibility traits。XCUI 沒有公開 API 讀 trait，
    /// 走 element snapshot 的 `traits`（KVC）；讀不到就 fail loud，不悄悄回 0 讓「占位圖不帶 image」假綠。
    private func cardButtonTraits(in app: XCUIApplication, title: String) throws -> UIAccessibilityTraits {
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "[\(title)] 相簿卡 button 沒渲染")
        let snapshot = try XCTUnwrap(try card.snapshot() as? NSObject, "[\(title)] 讀不到 element snapshot")
        let raw = try XCTUnwrap(snapshot.value(forKey: "traits") as? UInt64, "[\(title)] snapshot 沒有 traits")
        return UIAccessibilityTraits(rawValue: raw)
    }

    private func paperElement(in app: XCUIApplication, label: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "時間軸相簿卡（label「\(label)」）沒渲染")
        return element
    }

    /// 裁出 Caption 區：照片（printEdge 8＋190）下 7 起、扣底部 printEdgeBottom 8；左緣取 15（避開角托）、
    /// 右緣對稱。回傳的 raster 以裁切左緣為 x=0（`leftmostInkX` 需再加 15）。
    private func captionRaster(paper: XCUIElement, in app: XCUIApplication, context: String) throws -> InkRaster {
        // LS-407：卡片元素的 a11y frame＝紙面（`AlbumCardView` 用與紙同大的透明代理承載 a11y 元素，
        // 不再把染料池圓算進 frame，改前四邊各外擴 78——LS-406 的裁圖得扣 `PrintPhotoCardMetrics.mountPoolRadius()`）。
        let frame = paper.frame
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

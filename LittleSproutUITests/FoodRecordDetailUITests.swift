import XCTest

/// LS-381：飲食圖鑑 04 記錄詳情家族（`B8krzV`／`ygv7k`／`z1Pg2`／`gIo3O`／`vr5zj`／`GRB0y`／`Z8zWzZ`）的
/// 權限三態、內容順序、日期章、角托與對稿截圖——iPhone（compact）專用；iPad 見 `FoodRecordDetailIPadTests`。
/// host 見 `TapTargetGateHarness+FoodRecordDetail.swift`（小安，出生 2025-04-20）。
///
/// 截圖（`XCTAttachment` `.keepAlways`）：04／04b／04c × 淺深 × xSmall／預設／AX3，檔名 `LS-381-<板>-<色>-<字級>`。
@MainActor
final class FoodRecordDetailUITests: XCTestCase {
    private static let xSmall = "UICTContentSizeCategoryXS"
    private static let standard = "UICTContentSizeCategoryL"
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone（compact）版面；iPad 見 FoodRecordDetailIPadTests")
    }

    // MARK: - 權限三態按鈕集合（驗收 2）

    /// 04 作者：只有「編輯這筆記錄」（作者的刪除入口在 03b sheet 內，詳情頁不放）。
    func testAuthor_seesEditOnly() {
        let app = launch(.foodRecordDetail, Self.standard)
        XCTAssertEqual(actionButtons(in: app), ["編輯這筆記錄"])
    }

    /// 04c 非作者 owner：編輯鈕換成 `$danger`「刪除這筆記錄」（Notes `J8qvq5`）。
    func testNonAuthorOwner_seesDeleteOnly() {
        let app = launch(.foodRecordDetailOwner, Self.standard)
        XCTAssertEqual(actionButtons(in: app), ["刪除這筆記錄"])
        XCTAssertEqual(app.staticTexts["foodRecordDetail.recordedBy"].label, "爸爸記錄", "04c：記錄者是別人")
    }

    /// viewer：唯讀，一顆動作鈕都沒有。
    func testViewer_seesNoActions() {
        let app = launch(.foodRecordDetailViewer, Self.standard)
        XCTAssertEqual(actionButtons(in: app), [])
    }

    // MARK: - 內容與順序（範圍 1／3）

    func testAuthor_contentMatchesDesignInOrder() {
        let app = launch(.foodRecordDetail, Self.standard)
        let title = app.staticTexts["foodRecordDetail.title"]
        let stamp = element("foodRecordDetail.stamp", in: app)
        let photo = element("foodRecordDetail.photo", in: app)
        let reaction = element("foodRecordDetail.reaction", in: app)
        let note = app.staticTexts["foodRecordDetail.note"]
        let recordedBy = app.staticTexts["foodRecordDetail.recordedBy"]
        let allergen = element("foodRecordDetail.allergen", in: app)
        let edit = app.buttons["foodRecordDetail.edit"]

        XCTAssertEqual(title.label, "吐司麵包")
        XCTAssertEqual(stamp.label, "2026年6月8日 第一次吃到", "稿 `n8uwKm`：帶年、不補零")
        XCTAssertEqual(
            app.staticTexts["foodRecordDetail.imprint"].label, "小安 ·\u{00A0}1\u{00A0}歲\u{00A0}1\u{00A0}個月",
            "壓印行＝第一次吃那天的年齡（稿 `Iaasq`；VoiceOver 標籤會濾掉 U+2060，逐字元規則由單元測試鎖）"
        )
        XCTAssertEqual(reaction.label, "喜歡")
        XCTAssertEqual(note.label, "自己抓著吃，吃得滿臉都是麵包屑。")
        XCTAssertTrue(recordedBy.waitForLabel("媽媽記錄", timeout: 5))
        XCTAssertEqual(allergen.label, "含麩質（小麥、燕麥等穀物），是常見過敏原。只是提醒，不是醫療建議；有疑問請問醫師。")

        // 稿面 Body 順序：名稱 → 日期章 → 沖印品 → 反應 → 一句話 → 記錄者 → 過敏原（MJ-2：排在回憶之後）→ 編輯鈕。
        scrollUntilHittable(edit, in: app)
        let order = [title, stamp, photo, reaction, note, recordedBy, allergen, edit]
        for (upper, lower) in zip(order, order.dropFirst()) {
            XCTAssertLessThanOrEqual(
                upper.frame.maxY, lower.frame.minY + 1, "\(upper.identifier) 應在 \(lower.identifier) 之上"
            )
        }
    }

    // MARK: - 角托（範圍 2、驗收 2）

    /// 04：對角兩顆角托（Corner TL／BR）——左上、右下外角是 `$photo-corner`，右上、左下不是。
    func testPhotoPrint_hasDiagonalCornersOnly() {
        let app = launch(.foodRecordDetail, Self.standard)
        let photo = element("foodRecordDetail.photo", in: app).frame
        let imprint = app.staticTexts["foodRecordDetail.imprint"].frame
        // 沖印品外框＝照片窗外擴白邊 8（`$print-edge`），下緣到壓印行下方再 8（`$print-edge-bottom`）。
        let print = CGRect(
            x: photo.minX - 8, y: photo.minY - 8, width: photo.width + 16, height: imprint.maxY + 16 - photo.minY
        )
        XCTAssertEqual(print.width, app.frame.width - 48, accuracy: 1, "量測前自我檢查：沖印品全寬（扣 $screen-pad×2）")
        let ratios = cornerRatios(around: print, in: app)
        XCTAssertGreaterThan(ratios.topLeading, 0.8, "左上應有角托（像素佔比 \(ratios.topLeading)，沖印品 \(print)）")
        XCTAssertGreaterThan(ratios.bottomTrailing, 0.8, "右下應有角托（像素佔比 \(ratios.bottomTrailing)）")
        XCTAssertLessThan(ratios.topTrailing, 0.05, "右上不該有角托（像素佔比 \(ratios.topTrailing)）")
        XCTAssertLessThan(ratios.bottomLeading, 0.05, "左下不該有角托（像素佔比 \(ratios.bottomLeading)）")
    }

    /// 04b：空白沖印品零角托、整張可點（作者），邀請句逐字；沒有過敏原的南瓜整列隱藏。
    func testNoPhoto_blankPrintIsTappableWithoutCorners() {
        let app = launch(.foodRecordDetailNoPhoto, Self.standard)
        let addPhoto = app.buttons["foodRecordDetail.addPhoto"]
        XCTAssertTrue(addPhoto.waitForExistence(timeout: 5), "04b 作者：空白沖印品是按鈕")
        XCTAssertEqual(addPhoto.label, "加一張第一次吃南瓜的照片")
        XCTAssertEqual(element("foodRecordDetail.stamp", in: app).label, "2025年11月18日 第一次吃到")
        XCTAssertFalse(element("foodRecordDetail.allergen", in: app, timeout: 1).exists, "沒有過敏原：整列隱藏")
        XCTAssertEqual(addPhoto.frame.width, app.frame.width - 48, accuracy: 1, "量測前自我檢查：空白沖印品全寬")
        let ratios = cornerRatios(around: addPhoto.frame, in: app)
        for (name, ratio) in [
            ("左上", ratios.topLeading), ("右上", ratios.topTrailing),
            ("左下", ratios.bottomLeading), ("右下", ratios.bottomTrailing)
        ] {
            XCTAssertLessThan(ratio, 0.05, "04b 零角托：\(name)像素佔比 \(ratio)")
        }
        XCTAssertEqual(actionButtons(in: app), ["編輯這筆記錄"])
    }

    // MARK: - AX3（`z1Pg2`／`vr5zj`）

    /// AX3：貼紙與食物名直排（名稱貼左邊界，不在貼紙右側）；日期章 VoiceOver 仍念單行。
    func testAX3_identityStacksVerticallyAndStampStaysReadable() {
        let app = launch(.foodRecordDetail, Self.ax3)
        let title = app.staticTexts["foodRecordDetail.title"]
        XCTAssertLessThan(title.frame.minX, 40, "AX3 食物名直排在貼紙下方、貼左邊界（實際 minX \(title.frame.minX)）")
        XCTAssertEqual(element("foodRecordDetail.stamp", in: app).label, "2026年6月8日 第一次吃到")
        let standard = launch(.foodRecordDetail, Self.standard)
        XCTAssertGreaterThan(
            standard.staticTexts["foodRecordDetail.title"].frame.minX, 100, "預設字級食物名在貼紙（96）右側"
        )
    }

    // MARK: - 對稿截圖（驗收 1）

    func testScreenshots_04() { captureFamily(.foodRecordDetail, board: "04") }
    func testScreenshots_04b() { captureFamily(.foodRecordDetailNoPhoto, board: "04b") }
    func testScreenshots_04c() { captureFamily(.foodRecordDetailOwner, board: "04c") }

    // MARK: - helpers

    private func captureFamily(_ screen: TapTargetGateScreenName, board: String) {
        for (sizeName, size) in [("xSmall", Self.xSmall), ("default", Self.standard), ("AX3", Self.ax3)] {
            for isDark in [false, true] {
                let app = launch(screen, size, dark: isDark)
                XCTAssertTrue(element("foodRecordDetail.stamp", in: app).exists)
                attachScreenshot(app, "\(board)-\(isDark ? "dark" : "light")-\(sizeName)")
                if size == Self.ax3 || size == Self.standard {
                    app.swipeUp()
                    attachScreenshot(app, "\(board)-\(isDark ? "dark" : "light")-\(sizeName)-scrolled")
                }
            }
        }
    }

    private func launch(_ screen: TapTargetGateScreenName, _ size: String, dark: Bool = false) -> XCUIApplication {
        let app = TapTargetMeasurement.launch(
            screen, contentSizeCategory: size, extraLaunchArguments: dark ? ["-LSFoodRecordDetailDark", "YES"] : []
        )
        TapTargetMeasurement.assertScreenRendered(screen, in: app)
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 5) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        _ = element.waitForExistence(timeout: timeout)
        return element
    }

    /// 畫面上的動作鈕標籤集合（「編輯這筆記錄」／「刪除這筆記錄」），依稿面順序。
    private func actionButtons(in app: XCUIApplication) -> [String] {
        _ = element("foodRecordDetail.stamp", in: app)
        return ["foodRecordDetail.edit", "foodRecordDetail.delete"].compactMap { identifier in
            let button = app.buttons[identifier]
            return button.exists ? button.label : nil
        }
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
    }

    private struct CornerRatios {
        let topLeading: Double, topTrailing: Double, bottomLeading: Double, bottomTrailing: Double
    }

    /// 沖印品四個外角各取「外擴 5pt 起、邊長 12pt」的方塊（角托 26pt 外擴 5 的三角形完整蓋住這塊，且不碰到
    /// 照片本身——照片從白邊 8pt 內才開始），量接近 `$photo-corner` 淺色 #C89AA3 的像素佔比。
    private func cornerRatios(around frame: CGRect, in app: XCUIApplication) -> CornerRatios {
        let screenshot = app.screenshot().image
        guard let pixels = RGBAPixels(screenshot) else {
            XCTFail("截圖沒有 cgImage")
            return CornerRatios(topLeading: 0, topTrailing: 0, bottomLeading: 0, bottomTrailing: 0)
        }
        // XCUIScreenshot 的 `UIImage.scale` 不保證等於螢幕倍率——用點陣寬÷畫面點寬換算。
        let scale = CGFloat(pixels.width) / app.frame.width
        let out: CGFloat = 5, side: CGFloat = 12
        func ratio(_ originX: CGFloat, _ originY: CGFloat) -> Double {
            let box = CGRect(x: originX, y: originY, width: side, height: side)
            return pixels.ratio(in: box, scale: scale) { red, green, blue in
                abs(red - 0xC8) <= 14 && abs(green - 0x9A) <= 14 && abs(blue - 0xA3) <= 14
            }
        }
        return CornerRatios(
            topLeading: ratio(frame.minX - out, frame.minY - out),
            topTrailing: ratio(frame.maxX + out - side, frame.minY - out),
            bottomLeading: ratio(frame.minX - out, frame.maxY + out - side),
            bottomTrailing: ratio(frame.maxX + out - side, frame.maxY + out - side)
        )
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "LS-381-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// 截圖重畫進 8-bit sRGB 點陣（同 `FoodBookUITests.vividPixelRatio` 的取像手法），供角托像素量測。
struct RGBAPixels {
    private let bytes: [UInt8]
    let width: Int
    private let height: Int

    init?(_ image: UIImage) {
        guard let cgImage = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        width = cgImage.width
        height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let (imageWidth, imageHeight) = (width, height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: imageWidth, height: imageHeight, bitsPerComponent: 8,
                bytesPerRow: imageWidth * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            return true
        }
        guard drawn else { return nil }
        bytes = buffer
    }

    /// `rect` 為點座標；回傳符合 `matches` 的像素佔比（超出截圖範圍的部分不計）。
    func ratio(in rect: CGRect, scale: CGFloat, matches: (Int, Int, Int) -> Bool) -> Double {
        let minX = max(0, Int(rect.minX * scale)), maxX = min(width, Int(rect.maxX * scale))
        let minY = max(0, Int(rect.minY * scale)), maxY = min(height, Int(rect.maxY * scale))
        guard maxX > minX, maxY > minY else { return 0 }
        var hits = 0
        for row in minY..<maxY {
            for column in minX..<maxX {
                let offset = (row * width + column) * 4
                if matches(Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])) { hits += 1 }
            }
        }
        return Double(hits) / Double((maxX - minX) * (maxY - minY))
    }
}

private extension XCUIElement {
    func waitForLabel(_ label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
            == .completed
    }
}

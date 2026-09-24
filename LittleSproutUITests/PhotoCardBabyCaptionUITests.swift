import UIKit
import XCTest

/// LS-365：時間軸照片卡寶貝署名（`PhotoCardSignature`，LS-367 Notes `L0xP2`）——四態（一位／
/// 兩位／三位長名／未標記）× 三字級（xSmall／預設 L／AX3），外加相簿卡署名列折行回歸
/// （`AlbumSignatureFormatter.segment` 改「·」後 NBSP 會連帶改相簿卡，LS-367 範圍補記二 (b)）。
///
/// **為什麼量像素、不量 `frame`**：「小安」／「· 2 歲 3 個月」與「小安 ·」／「2 歲 3 個月」
/// 兩種折法行數、高度完全相同，a11y label 也是同一串字——只有畫出來的像素看得出「·」落在哪
/// 一行。做法：截圖裁出署名範圍，列掃描找出墨色（`$print-ink-secondary` #553040，紙
/// `$print-paper` 淺深皆遠亮於它）行帶＝文字行；每一行的最後／第一個「字形群」（相鄰墨色欄）
/// 若垂直高度不到行高的 35%，就是「·」這個小圓點（CJK 字、數字、拉丁字母都遠高於它）。
///
/// 斷言對應稿面規則：
///   - 任何一行都**不以「·」結尾**（NBSP 讓「·」黏住後面的年齡）；
///   - AX3 單人放不下時必有一行**以「·」開頭**（姓名後折行、「·」領銜下一行）；
///   - 行數：串接放得下就一行，放不下一行一人（`ViewThatFits(in: .horizontal)`）。
@MainActor
final class PhotoCardBabyCaptionUITests: XCTestCase {
    private static let xSmall = "UICTContentSizeCategoryXS"
    private static let large = "UICTContentSizeCategoryL"
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"

    // MARK: - 一位寶貝

    func testOneChild_xSmallAndDefault_singleLine() throws {
        for size in [Self.xSmall, Self.large] {
            let lines = try signatureLines(fixture: "one", size: size)
            XCTAssertEqual(lines.count, 1, "[\(size)] 一位寶貝應為單行「小安 · 2 歲 3 個月」，量到 \(lines.count) 行")
            assertNoLineEndsWithDot(lines, context: "one/\(size)")
        }
    }

    func testOneChild_ax3_labelIsOneSentence_andNoDanglingDot() throws {
        let app = launch(fixture: "one", size: Self.ax3)
        let signature = signatureElement(in: app)
        XCTAssertEqual(
            spoken(signature.label), "小安 · 2 歲 3 個月", "VoiceOver 應念成一句「暱稱 · 年齡」，實際：\(signature.label)"
        )
        let lines = try inkLines(of: signature.frame, in: app)
        attachScreenshot(app, name: "one-AX3")
        assertNoLineEndsWithDot(lines, context: "one/AX3")
        if lines.count > 1 {
            XCTAssertTrue(lines[1].startsWithDot, "AX3 折行時第二行應由「·」領銜（LS-201 核可稿），實際沒有")
        }
    }

    // MARK: - 兩位寶貝

    func testTwoChildren_xSmallAndDefault_joinedOnOneLine() throws {
        for size in [Self.xSmall, Self.large] {
            let lines = try signatureLines(fixture: "two", size: size)
            XCTAssertEqual(
                lines.count, 1,
                "[\(size)] 兩位短名字「小安 · 2 歲 3 個月、小明 · 8 個月大」放得下一行就該串接成一行，量到 \(lines.count) 行"
            )
        }
    }

    func testTwoChildren_ax3_oneLinePerPerson_readAsOneElement() throws {
        let app = launch(fixture: "two", size: Self.ax3)
        let signature = signatureElement(in: app)
        XCTAssertTrue(
            signature.label.contains("小安") && signature.label.contains("小明"),
            "多寶貝應 `.combine` 成一個元素、兩個名字都在同一個 label 裡，實際：\(signature.label)"
        )
        let lines = try inkLines(of: signature.frame, in: app)
        attachScreenshot(app, name: "two-AX3")
        XCTAssertGreaterThanOrEqual(
            lines.count, 2, "AX3 串接放不下一行，應改一行一人（至少兩行），量到 \(lines.count) 行——ViewThatFits 沒生效？"
        )
        assertNoLineEndsWithDot(lines, context: "two/AX3")
    }

    // MARK: - 三位寶貝（長名字＋拉丁名）

    func testThreeLongNames_xSmallAndDefault_oneLinePerPerson() throws {
        for size in [Self.xSmall, Self.large] {
            let lines = try signatureLines(fixture: "three", size: size)
            XCTAssertEqual(
                lines.count, 3,
                "[\(size)] 三位長名字串接放不下一行 → 應一行一人共 3 行，量到 \(lines.count) 行——ViewThatFits 沒生效？"
            )
            assertNoLineEndsWithDot(lines, context: "three/\(size)")
        }
    }

    func testThreeLongNames_ax3_wrapsAfterNameWithDotLeadingNextLine() throws {
        let app = launch(fixture: "three", size: Self.ax3)
        let signature = signatureElement(in: app)
        let lines = try inkLines(of: signature.frame, in: app)
        attachScreenshot(app, name: "three-AX3")
        XCTAssertGreaterThan(lines.count, 3, "AX3 三位長名字每人至少一人要折行，量到 \(lines.count) 行")
        assertNoLineEndsWithDot(lines, context: "three/AX3")
        XCTAssertTrue(
            lines.contains(where: \.startsWithDot),
            "AX3「歐陽彥廷 · 2 歲 3 個月」放不下一行，應在姓名後折行、由「·」領銜下一行——沒有任何一行以「·」開頭"
        )
    }

    // MARK: - 未標記

    func testUntagged_blankCaptionHidden_cardHeightUnchanged() throws {
        for size in [Self.xSmall, Self.large, Self.ax3] {
            let untagged = launch(fixture: "none", size: size)
            let untaggedCard = untagged.descendants(matching: .any)["harness.photoCard"]
            XCTAssertTrue(untaggedCard.waitForExistence(timeout: 10), "[\(size)] 未標記照片卡沒渲染")
            XCTAssertFalse(
                untagged.descendants(matching: .any)[QAAccessibilityID.photoCardSignature].exists,
                "[\(size)] 未標記的空白署名行要 accessibilityHidden，不念「未標記」"
            )
            attachScreenshot(untagged, name: "none-\(size)")
            let untaggedHeight = untaggedCard.frame.height
            untagged.terminate()

            let tagged = launch(fixture: "one", size: size)
            let taggedCard = tagged.descendants(matching: .any)["harness.photoCard"]
            XCTAssertTrue(taggedCard.waitForExistence(timeout: 10))
            let taggedLines = try inkLines(of: signatureElement(in: tagged).frame, in: tagged)
            let taggedHeight = taggedCard.frame.height
            tagged.terminate()
            if taggedLines.count == 1 {
                // 單行署名 vs 留白：同一行高，卡高必須一樣（定案 2 `LMMks`：留白不塌縮）。
                XCTAssertEqual(
                    untaggedHeight, taggedHeight, accuracy: 1,
                    "[\(size)] 未標記卡高 \(untaggedHeight) ≠ 單行署名卡高 \(taggedHeight)——留白行塌縮了"
                )
            } else {
                // AX3 有字的卡折行、未標記只佔一行：差距必須剛好是多出來的行，未標記不能更矮到塌縮。
                XCTAssertLessThan(untaggedHeight, taggedHeight, "[\(size)] 折行卡應比留白卡高")
                XCTAssertGreaterThan(
                    untaggedHeight, taggedHeight - taggedLines.lineHeight * CGFloat(taggedLines.count),
                    "[\(size)] 未標記卡高 \(untaggedHeight) 連一行署名高度都沒留（\(taggedHeight) 扣掉全部署名行）"
                )
            }
        }
    }

    // MARK: - feed 接線（TimelineView → PhotoCardView）

    func testFeed_taggedEntryShowsSignature_untaggedShowsNone() {
        let app = launch(fixture: "feed", size: Self.large)
        let signatures = app.descendants(matching: .any).matching(identifier: QAAccessibilityID.photoCardSignature)
        XCTAssertTrue(signatures.firstMatch.waitForExistence(timeout: 10), "時間軸有標記的照片卡沒有署名")
        XCTAssertEqual(
            signatures.count, 1, "feed 兩張照片卡只有一張有標記，應只有一個署名元素，實際 \(signatures.count)"
        )
        XCTAssertEqual(
            spoken(signatures.firstMatch.label), "小安 · 2 歲 3 個月",
            "年齡基準應是 feed_items.occurred_at（2026-09-15），不是現在；實際：\(signatures.firstMatch.label)"
        )
        attachScreenshot(app, name: "feed-L")
    }

    // MARK: - 相簿卡折行回歸（GF3Nx）

    func testAlbumCardSignature_ax3_noDanglingDot_dotLeadsWrappedLine() throws {
        let app = launch(fixture: "album", size: Self.ax3)
        let card = app.descendants(matching: .any)["harness.albumCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "相簿卡沒渲染")
        // 只量照片（printEdge 8＋184）與 VStack 間距 7 以下的文字區，扣掉底部 printEdgeBottom 8。
        let frame = card.frame
        let textArea = CGRect(
            x: frame.minX + 8, y: frame.minY + 199, width: frame.width - 16, height: frame.height - 207
        )
        let lines = try inkLines(of: textArea, in: app)
        attachScreenshot(app, name: "album-AX3")
        assertNoLineEndsWithDot(lines, context: "album/AX3")
        XCTAssertTrue(
            lines.contains(where: \.startsWithDot),
            "相簿卡 AX3「Charlotte Chen · 2 歲 3 個月」應在姓名後折行、由「·」領銜下一行（LS-201 核可稿 GF3Nx）"
        )
    }

    // MARK: - helpers

    /// a11y label 會吞掉 WORD JOINER（U+2060），NBSP 則保留——逐字元比對交給單元測試
    /// （`AlbumSignatureFormatterTests`），這裡只比「念出來的字」。
    private func spoken(_ label: String) -> String {
        label.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func launch(fixture: String, size: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = TapTargetGateScreenName.photoCardBabyCaption.rawValue
        app.launchEnvironment["LS_PHOTO_CARD_CAPTION_FIXTURE"] = fixture
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        app.launch()
        return app
    }

    private func signatureElement(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line)
        -> XCUIElement {
        let element = app.descendants(matching: .any)[QAAccessibilityID.photoCardSignature]
        XCTAssertTrue(element.waitForExistence(timeout: 10), "照片卡署名元素沒出現", file: file, line: line)
        return element
    }

    private func signatureLines(fixture: String, size: String) throws -> InkLines {
        let app = launch(fixture: fixture, size: size)
        let lines = try inkLines(of: signatureElement(in: app).frame, in: app)
        attachScreenshot(app, name: "\(fixture)-\(size)")
        app.terminate()
        return lines
    }

    private func assertNoLineEndsWithDot(
        _ lines: InkLines, context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        for (index, inkLine) in lines.lines.enumerated() where inkLine.endsWithDot {
            XCTFail(
                "[\(context)] 第 \(index + 1) 行以「·」結尾——「·」後應是 NBSP、黏住年齡，"
                    + "不該折成「姓名 ·」／「年齡」（LS-367 Notes L0xP2 ①）",
                file: file, line: line
            )
        }
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "LS-365-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func inkLines(of rect: CGRect, in app: XCUIApplication) throws -> InkLines {
        let screenshot = app.screenshot().image
        let cgImage = try XCTUnwrap(screenshot.cgImage, "截圖沒有 cgImage")
        let raster = try XCTUnwrap(InkRaster(cgImage: cgImage, scale: screenshot.scale, rect: rect), "裁切署名範圍失敗")
        return raster.lines()
    }
}

/// 一行文字的墨色量測結果（單位：點）。
private struct InkLine {
    let height: CGFloat
    let firstGlyphHeight: CGFloat
    let lastGlyphHeight: CGFloat

    /// 「·」高度約字級 12%（AX3 40pt 下約 5pt），CJK／數字／拉丁小寫都 ≥ 行高 50%。
    private static let dotRatio: CGFloat = 0.35
    var startsWithDot: Bool { firstGlyphHeight < height * Self.dotRatio }
    var endsWithDot: Bool { lastGlyphHeight < height * Self.dotRatio }
}

private struct InkLines {
    let lines: [InkLine]
    var count: Int { lines.count }
    subscript(index: Int) -> InkLine { lines[index] }
    func contains(where predicate: (InkLine) -> Bool) -> Bool { lines.contains(where: predicate) }
    /// 最高一行的墨色高度，當「一行大概多高」的下界估計用。
    var lineHeight: CGFloat { lines.map(\.height).max() ?? 0 }
}

/// 把截圖裁成署名範圍的灰階墨色點陣（`true`＝墨）。
private struct InkRaster {
    private let ink: [[Bool]]
    private let scale: CGFloat
    /// 亮度低於此值才算墨：墨 #553040 ≈ 0.23，紙淺 #FBEBEC／深 #E8D9D4 ≥ 0.86。
    private static let inkLuminance: Double = 0.45

    init?(cgImage: CGImage, scale: CGFloat, rect: CGRect) {
        let pixelRect = CGRect(
            x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard !pixelRect.isEmpty, let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        let width = cropped.width
        let height = cropped.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        var ink = [[Bool]](repeating: [Bool](repeating: false, count: width), count: height)
        for row in 0..<height {
            for col in 0..<width {
                let offset = (row * width + col) * 4
                let luminance = (0.2126 * Double(buffer[offset]) + 0.7152 * Double(buffer[offset + 1])
                    + 0.0722 * Double(buffer[offset + 2])) / 255
                ink[row][col] = luminance < Self.inkLuminance
            }
        }
        self.ink = ink
        self.scale = scale
    }

    /// 連續有墨的列＝一行（行距空白把行與行分開）；每行再找第一／最後一個字形群的墨色高度。
    func lines() -> InkLines {
        var result: [InkLine] = []
        var row = 0
        while row < ink.count {
            guard ink[row].contains(true) else { row += 1; continue }
            let top = row
            while row < ink.count, ink[row].contains(true) { row += 1 }
            let band = top..<row
            // 過濾抗鋸齒雜點：一行墨色至少 3pt 高。
            guard CGFloat(band.count) / scale >= 3 else { continue }
            let columns = inkColumns(in: band)
            guard let first = columns.first, let last = columns.last else { continue }
            // 字形群的分界：空白欄寬 ≥ 行高 20%（約 0.18em）。CJK 字內筆畫間、字與字之間的縫都
            // 小於這個值；「·」兩側有空白（U+0020／U+00A0 約 0.25em）一定會被切成獨立一群。
            let maxGap = max(1, Int(CGFloat(band.count) * 0.2))
            let firstRun = run(from: first, in: columns, forward: true, maxGap: maxGap)
            let lastRun = run(from: last, in: columns, forward: false, maxGap: maxGap)
            result.append(InkLine(
                height: CGFloat(band.count) / scale,
                firstGlyphHeight: glyphHeight(band: band, columns: firstRun),
                lastGlyphHeight: glyphHeight(band: band, columns: lastRun)
            ))
        }
        return InkLines(lines: result)
    }

    private func inkColumns(in band: Range<Int>) -> [Int] {
        guard let width = ink.first?.count else { return [] }
        return (0..<width).filter { col in band.contains { ink[$0][col] } }
    }

    /// 從最左（或最右）墨色欄開始、欄間空白小於 `maxGap` 的一段欄＝一個字形群。
    private func run(from start: Int, in columns: [Int], forward: Bool, maxGap: Int) -> [Int] {
        let ordered = forward ? columns : columns.reversed()
        var run = [start]
        for col in ordered.dropFirst() {
            guard abs(col - run[run.count - 1]) <= maxGap else { break }
            run.append(col)
        }
        return run
    }

    private func glyphHeight(band: Range<Int>, columns: [Int]) -> CGFloat {
        let rows = band.filter { row in columns.contains { ink[row][$0] } }
        guard let top = rows.first, let bottom = rows.last else { return 0 }
        return CGFloat(bottom - top + 1) / scale
    }
}

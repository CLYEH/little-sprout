@testable import LittleSprout
import SwiftUI
import XCTest

/// LS-389（LS-372 Notes `SLL6R`／量法 `AgS9H`）：相簿 tab 卡（`AlbumSummaryCardView`）與時間軸照片卡
/// （`PhotoCardView`）白邊上的署名列。LS-368 R1 在深色量到署名帶最左約 10pt 只有 4.05–4.49:1——
/// 字貼著 printEdge 8 起跑，正好落進左下角染料池（`$mount-pool` 深 #0D0609）最暗的那一圈。
/// 契約兩件事缺一不可：① 文字列在 printEdge 之內再內縮 `$sp-group` 12（字起點＝紙左緣 20＝日記卡
/// `$inset-card`，同軸）；② 染料池改用稿面元件值 `.card`，不沿用歡迎頁 `.welcome`（只做①時最低墨點
/// 4.51，餘裕小於模型誤差）。
///
/// 這裡用 `ImageRenderer` 把**整張卡**（不是拆出來的子元件）畫出來，照 `AgS9H` 量：以紙左緣為
/// x=0 逐 10pt 帶，在署名最後一行的字形縱向範圍內，取「非字形、落在紙色→池色直線上」的最暗像素
/// 當背景，對 `$print-ink-secondary` 算 WCAG 2.1 對比。模擬器截圖實測另見 handoff（驗收以實測為準）；
/// 這支是 push gate 上的回歸防線。
@MainActor
final class CardImprintInsetContrastTests: XCTestCase {
    private static let elderMinimumContrast = 4.5
    private static let scale: CGFloat = 3
    /// iPhone 17 Pro 402pt 扣兩側 `screenPad`。
    private static let cardWidth: CGFloat = 402 - 2 * AppSpacing.screenPad
    /// 卡外留白：扇影（相簿卡 y −18）與角托（外凸 5）畫得進來，紙左上角落在 (margin, margin)。
    private static let margin: CGFloat = 30

    // MARK: - ② preset

    /// 稿面 `cmp/Card Photo` `boZpu`／`cmp/Card Album` `r6cYjT` 四顆 radial 漸層的 opacity（中心
    /// (0,0)／(1,0)／(0,1)／(1,1)）。值寫死在這裡而不是從 `.card` 讀：這支要抓的正是「有人把 preset
    /// 改回 `.welcome` 或改成別的數字」。
    func test_cardPreset_matchesPenCardComponentGradients() {
        let card = PrintPhotoCard.MountPoolOpacity.card
        XCTAssertEqual(card.topLeading, 0.393, accuracy: 0.0005, "左上池應為稿面 0.393（SLL6R ②）")
        XCTAssertEqual(card.topTrailing, 0.259, accuracy: 0.0005, "右上池應為稿面 0.259（SLL6R ②）")
        XCTAssertEqual(card.bottomLeading, 0.293, accuracy: 0.0005, "左下池應為稿面 0.293（SLL6R ②）")
        XCTAssertEqual(card.bottomTrailing, 0.197, accuracy: 0.0005, "右下池應為稿面 0.197（SLL6R ②）")
    }

    /// 歡迎頁 `.welcome` 不在本票範圍（票文「不做」）——改到它會連帶改 01 歡迎頁與 04 三岔路。
    func test_welcomePreset_unchanged() {
        let welcome = PrintPhotoCard.MountPoolOpacity.welcome
        XCTAssertEqual(welcome.topLeading, 0.494, accuracy: 0.0005)
        XCTAssertEqual(welcome.topTrailing, 0.288, accuracy: 0.0005)
        XCTAssertEqual(welcome.bottomLeading, 0.36, accuracy: 0.0005)
        XCTAssertEqual(welcome.bottomTrailing, 0.236, accuracy: 0.0005)
    }

    // MARK: - ①＋② 渲染實量

    func test_albumSummaryCard_signatureStartsOnInsetCardAxis_andMeetsElderContrast() throws {
        for scheme in [ColorScheme.dark, .light] {
            let card = AlbumSummaryCardView(
                album: AlbumSummary(
                    id: UUID(), title: "上禮拜的動物園一日遊", photoCount: 12, cover: nil, childIds: [],
                    createdAt: Date()
                ),
                taggedChildren: Self.children(asOf: Date()),
                cardWidth: Self.cardWidth
            )
            let measurement = try measure(card, photoHeight: 184, scheme: scheme)
            assertInsetAndContrast(measurement, card: "相簿卡", scheme: scheme)
            // ③：串接放不下一行 → 一行一人（Caption＋3 人＝4 行）。自然斷行會把「Gary」與「· 8 個月大」
            // 拆在兩行、只剩 Caption＋2 行（LS-389 改前實測）。
            XCTAssertEqual(
                measurement.lineCount, 4, "相簿卡三位寶貝放不下一行，應 Caption＋一行一人共 4 行，量到 \(measurement.lineCount)"
            )
        }
    }

    func test_photoCard_signatureStartsOnInsetCardAxis_andMeetsElderContrast() throws {
        let occurredAt = Date()
        for scheme in [ColorScheme.dark, .light] {
            let card = PhotoCardView(
                content: MediaContent(
                    id: UUID(), type: .photo, width: 4, height: 3, thumbWidth: nil, thumbHeight: nil,
                    storagePath: "preview/photo.jpg", isThumbnail: false, signedURL: nil, durationSeconds: nil
                ),
                taggedChildren: Self.children(asOf: occurredAt), occurredAt: occurredAt,
                timelineStore: .preview(), familyStore: .preview()
            )
            let measurement = try measure(card, photoHeight: 184, scheme: scheme)
            assertInsetAndContrast(measurement, card: "照片卡", scheme: scheme)
            XCTAssertEqual(
                measurement.lineCount, 3, "照片卡三位寶貝放不下一行，應一行一人共 3 行，量到 \(measurement.lineCount)"
            )
        }
    }

    // MARK: - helpers

    /// 最後一行是「Gary · 8 個月大」——有下伸部的拉丁名（SLL6R 指定測資），且在多寶貝的最後一行、最靠近
    /// 左下角池。長名字確保三人串接放不下一行、走一行一人。
    private static func children(asOf date: Date) -> [Child] {
        func child(_ name: String, years: Int, months: Int) -> Child {
            let birthday = Calendar.current.date(byAdding: DateComponents(year: -years, month: -months), to: date)!
            return Child(id: UUID(), name: name, birthday: birthday, avatarURL: nil, deletedAt: nil, createdAt: date)
        }
        return [
            child("歐陽彥廷", years: 2, months: 3), child("小饅頭", years: 1, months: 8), child("Gary", years: 0, months: 8)
        ]
    }

    private func assertInsetAndContrast(
        _ measurement: Measurement, card: String, scheme: ColorScheme,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let axis = AppSpacing.printEdge + AppSpacing.group
        let context = "[\(card)/\(scheme)]"
        XCTAssertEqual(
            axis, AppSpacing.insetCard, "字起點（紙左緣 printEdge＋sp-group）應與日記卡 inset-card 同軸",
            file: file, line: line
        )
        // 字形左側 bearing 約 0.5–2pt：起點必須在 [20, 23)，拿掉內縮會落在 ~8–11。
        XCTAssertGreaterThanOrEqual(
            measurement.textStartX, axis, "\(context) 文字最左墨點離紙左緣 \(measurement.textStartX)pt，應 ≥ \(axis)",
            file: file, line: line
        )
        XCTAssertLessThan(
            measurement.textStartX, axis + 3, "\(context) 文字最左墨點離紙左緣 \(measurement.textStartX)pt，偏離 \(axis) 太多",
            file: file, line: line
        )
        XCTAssertNotNil(
            measurement.bandContrasts[Int(axis)], "\(context) 量不到字起點帶 [20,30)", file: file, line: line
        )
        assertBottomLeadingPoolIsCardPreset(measurement, context: context, file: file, line: line)
        let bands = measurement.bandContrasts.sorted { $0.key < $1.key }
        for (band, ratio) in bands {
            XCTAssertGreaterThanOrEqual(
                ratio, Self.elderMinimumContrast,
                "\(context) 署名末行帶 [\(band),\(band + 10)) 對紙只有 \(String(format: "%.2f", ratio)):1（AgS9H 量法）",
                file: file, line: line
            )
        }
        let summary = bands.map { "[\($0.key),\($0.key + 10))=\(String(format: "%.2f", $0.value))" }
        let joined = summary.joined(separator: " ")
        print("LS-389 \(context) textStartX=\(measurement.textStartX) lines=\(measurement.lineCount) \(joined)")
        print("LS-389 \(context) bottomLeadingPoolPosition=\(measurement.bottomLeadingPoolPosition)")
    }

    /// ②：卡片實際畫出來的左下池要是 `.card`（0.293），不是 `.welcome`（0.36）——preset 常數測試抓不到
    /// 「定義對了、卡片卻沒用它」。池是半徑 R＝角托 26×3＝78 的線性 radial（α(d)＝α0×(1−d/R)），在紙左緣
    /// 內 2pt、紙底上 40pt 取樣（避開角托三角 21pt 與文字），量到的沿線位置要比較接近 `.card` 的預期值。
    private func assertBottomLeadingPoolIsCardPreset(
        _ measurement: Measurement, context: String, file: StaticString, line: UInt
    ) {
        let falloff = 1 - (2.0 * 2 + 40.0 * 40).squareRoot() / 78
        let expectedCard = PrintPhotoCard.MountPoolOpacity.card.bottomLeading * falloff
        let expectedWelcome = PrintPhotoCard.MountPoolOpacity.welcome.bottomLeading * falloff
        let measured = measurement.bottomLeadingPoolPosition
        XCTAssertLessThan(
            abs(measured - expectedCard), abs(expectedWelcome - expectedCard) / 2,
            "\(context) 左下池取樣 α≈\(String(format: "%.3f", measured))，預期 .card \(String(format: "%.3f", expectedCard))"
                + "（.welcome 會是 \(String(format: "%.3f", expectedWelcome))）——卡片沒用稿面 preset？",
            file: file, line: line
        )
    }

    private struct Measurement {
        /// 文字最左墨點離紙左緣（pt）。
        let textStartX: CGFloat
        let lineCount: Int
        /// 署名最後一行：帶起點（pt，紙左緣 x=0）→ 該帶最暗背景對 `$print-ink-secondary` 的對比。
        let bandContrasts: [Int: Double]
        /// 紙左緣內 2pt、紙底往上 40pt 那一點的染料池沿線位置（0＝紙、1＝全池），推回左下池的 α。
        let bottomLeadingPoolPosition: Double
    }

    private func measure(_ view: some View, photoHeight: CGFloat, scheme: ColorScheme) throws -> Measurement {
        let content = view
            .frame(width: Self.cardWidth)
            .padding(Self.margin)
            .background(Color(red: 0, green: 1, blue: 0))
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.scale
        let pixels = try SRGBPixels(try XCTUnwrap(renderer.cgImage, "ImageRenderer 沒有產出影像"))
        let raster = ImprintRaster(
            pixels: pixels, scale: Self.scale, paperOrigin: Self.margin, paperWidth: Self.cardWidth,
            photoHeight: photoHeight, paper: rgb(.lsPrintPaper, scheme), pool: rgb(.lsMountPool, scheme)
        )
        let textStart = try XCTUnwrap(raster.textStartColumn, "文字區沒有任何字形像素")
        let lines = raster.lines()
        let lastLine = try XCTUnwrap(lines.last, "文字區找不到任何一行")
        let inkLuminance = luminance(.lsPrintInkSecondary, scheme)
        return Measurement(
            textStartX: CGFloat(textStart - raster.paperLeft) / Self.scale,
            lineCount: lines.count,
            bandContrasts: raster.darkestBackgroundByBand(in: lastLine)
                .mapValues { ($0 + 0.05) / (inkLuminance + 0.05) },
            bottomLeadingPoolPosition: raster.poolPosition(paperX: 2, abovePaperBottom: 40)
        )
    }

    private func resolved(_ color: Color, _ scheme: ColorScheme) -> Color.Resolved {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return color.resolve(in: environment)
    }

    private func rgb(_ color: Color, _ scheme: ColorScheme) -> SIMD3<Double> {
        let value = resolved(color, scheme)
        return SIMD3(Double(value.red), Double(value.green), Double(value.blue)) * 255
    }

    private func luminance(_ color: Color, _ scheme: ColorScheme) -> Double {
        let value = resolved(color, scheme)
        return 0.2126 * Double(value.linearRed) + 0.7152 * Double(value.linearGreen) + 0.0722 * Double(value.linearBlue)
    }
}

/// 卡片渲染結果裡「紙上文字區」的點陣分析（AgS9H 量法的幾何與像素分類）。
private struct ImprintRaster {
    let pixels: SRGBPixels
    let scale: CGFloat
    let paperLeft: Int
    let paperBottom: Int
    /// 文字區：照片下緣以下、底邊 printEdgeBottom 以上；左右避開 printEdge 內的角托。
    let rows: Range<Int>
    let columns: Range<Int>
    private let paper: SIMD3<Double>
    private let axis: SIMD3<Double>
    /// 字形＝明顯離開紙色→池色直線（> 8，8-bit）的像素——墨 #553040 帶紅相，池近中性。
    private let glyph: Set<Int>

    init(
        pixels: SRGBPixels, scale: CGFloat, paperOrigin: CGFloat, paperWidth: CGFloat, photoHeight: CGFloat,
        paper: SIMD3<Double>, pool: SIMD3<Double>
    ) {
        func toPixel(_ points: CGFloat) -> Int { Int((points * scale).rounded()) }
        self.pixels = pixels
        self.scale = scale
        self.paper = paper
        axis = pool - paper
        paperLeft = toPixel(paperOrigin)
        let paperRight = toPixel(paperOrigin + paperWidth)
        // 紙底：從照片下緣沿卡片中線往下找第一個哨兵色（相簿卡紙外無物；照片卡紙下是 8pt 空隙＋互動列）。
        let midColumn = (paperLeft + paperRight) / 2
        var paperBottom = toPixel(paperOrigin + AppSpacing.printEdge + photoHeight)
        while paperBottom < pixels.height, pixels.rgb(column: midColumn, row: paperBottom) != SIMD3(0, 255, 0) {
            paperBottom += 1
        }
        self.paperBottom = paperBottom
        let textTop = toPixel(paperOrigin + AppSpacing.printEdge + photoHeight + 1)
        rows = textTop..<max(textTop, paperBottom - toPixel(AppSpacing.printEdgeBottom))
        columns = (paperLeft + toPixel(AppSpacing.printEdge + 1))..<(paperRight - toPixel(AppSpacing.printEdge + 1))
        var glyph = Set<Int>()
        for row in rows {
            for column in columns where Self.onLine(pixels.rgb(column: column, row: row), paper, axis).distance > 8 {
                glyph.insert(row * pixels.width + column)
            }
        }
        self.glyph = glyph
    }

    /// 像素離紙色→池色直線的距離（8-bit），與沿線位置（0＝紙、1＝全池）。
    private static func onLine(
        _ pixel: SIMD3<Double>, _ paper: SIMD3<Double>, _ axis: SIMD3<Double>
    ) -> (distance: Double, position: Double) {
        let position = ((pixel - paper) * axis).sum() / (axis * axis).sum()
        let delta = pixel - (paper + axis * position)
        return ((delta * delta).sum().squareRoot(), position)
    }

    /// 紙上某點的顏色落在紙色→池色直線的哪裡（0＝紙、1＝全池）＝該點疊上的池 α。
    func poolPosition(paperX: CGFloat, abovePaperBottom: CGFloat) -> Double {
        let column = paperLeft + Int((paperX * scale).rounded())
        let row = paperBottom - Int((abovePaperBottom * scale).rounded())
        return Self.onLine(pixels.rgb(column: column, row: row), paper, axis).position
    }

    var textStartColumn: Int? { glyph.map { $0 % pixels.width }.min() }

    private func isGlyph(column: Int, row: Int) -> Bool { glyph.contains(row * pixels.width + column) }

    private func rowHasGlyph(_ row: Int) -> Bool { columns.contains { isGlyph(column: $0, row: row) } }

    /// 行＝連續有字形的列；過濾 < 3pt 的雜點帶。
    func lines() -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var row = rows.lowerBound
        while row < rows.upperBound {
            guard rowHasGlyph(row) else { row += 1; continue }
            let top = row
            while row < rows.upperBound, rowHasGlyph(row) { row += 1 }
            if CGFloat(row - top) / scale >= 3 { lines.append(top..<row) }
        }
        return lines
    }

    /// 背景＝落在直線上、且 2px 內沒有字形（排除反鋸齒邊緣）的像素；逐 10pt 帶取最暗的亮度。
    /// 只回傳該行有字形的帶。
    func darkestBackgroundByBand(in line: Range<Int>) -> [Int: Double] {
        var darkest: [Int: Double] = [:]
        var bandsWithGlyph = Set<Int>()
        for row in line {
            for column in columns {
                let band = Int((CGFloat(column - paperLeft) / scale) / 10) * 10
                if isGlyph(column: column, row: row) {
                    bandsWithGlyph.insert(band)
                } else if isCleanBackground(column: column, row: row) {
                    darkest[band] = min(darkest[band] ?? 1, pixels.luminance(column: column, row: row))
                }
            }
        }
        return darkest.filter { bandsWithGlyph.contains($0.key) }
    }

    private func isCleanBackground(column: Int, row: Int) -> Bool {
        let line = Self.onLine(pixels.rgb(column: column, row: row), paper, axis)
        guard line.distance <= 3, line.position >= -0.02 else { return false }
        let near = (-2...2).contains { rowOffset in
            (-2...2).contains { isGlyph(column: column + $0, row: row + rowOffset) }
        }
        return !near
    }
}

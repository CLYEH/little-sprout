import SwiftUI

/// 相簿紙語言的 signature 元素（`cmp/Photo Corner`，LS-46 三個記憶點之一）：壓在沖印品四角
/// 的三角形紙托。每個角是一個直角三角形，直角頂點落在照片外角，斜邊（fold line）朝內，
/// 用 `$corner-fold` 描一條淡邊表示紙的摺痕。
///
/// 角托本身不吃 Dynamic Type（Handoff Notes「角托三段規則」）：呼叫端應該傳固定尺寸
/// （`AppSpacing` 之外的字面值 26／40，對應 .pen 稿的角托尺寸），不要用 `@ScaledMetric`。
enum PhotoCorner: CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
}

struct PhotoCornerShape: Shape {
    let corner: PhotoCorner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let topRight = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)

        switch corner {
        case .topLeading:
            path.move(to: topLeft)
            path.addLine(to: topRight)
            path.addLine(to: bottomLeft)
        case .topTrailing:
            path.move(to: topRight)
            path.addLine(to: topLeft)
            path.addLine(to: bottomRight)
        case .bottomLeading:
            path.move(to: bottomLeft)
            path.addLine(to: topLeft)
            path.addLine(to: bottomRight)
        case .bottomTrailing:
            path.move(to: bottomRight)
            path.addLine(to: topRight)
            path.addLine(to: bottomLeft)
        }
        path.closeSubpath()
        return path
    }

    /// 摺痕斜邊，與 `path(in:)` 的斜邊重合，另外描邊表示紙的摺線。跟 `path(in:)` 一樣吃
    /// `rect` 換算實際座標——不能回傳寫死 0/1 的 `Path`，那樣線只會畫在 1pt 見方的角落，
    /// 不會跟著呼叫端傳入的角托尺寸縮放。
    func foldEdge(in rect: CGRect) -> Path {
        var path = Path()
        switch corner {
        case .topLeading:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .topTrailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottomLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottomTrailing:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        return path
    }
}

/// 一張沖印品四個角托的疊層，壓在台紙上（外擴 `AppSpacing.cornerOut`）。
struct PhotoCornerOverlay: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            ForEach(PhotoCorner.allCases, id: \.self) { corner in
                cornerView(corner)
            }
        }
    }

    @ViewBuilder
    private func cornerView(_ corner: PhotoCorner) -> some View {
        let shape = PhotoCornerShape(corner: corner)
        ZStack {
            shape.fill(Color.lsPhotoCorner)
            shape.foldEdge(in: CGRect(x: 0, y: 0, width: size, height: size))
                .stroke(Color.lsCornerFold, lineWidth: 1.5)
        }
        .frame(width: size, height: size)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: corner))
        .offset(offset(for: corner))
    }

    private func alignment(for corner: PhotoCorner) -> Alignment {
        switch corner {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    private func offset(for corner: PhotoCorner) -> CGSize {
        let out = AppSpacing.cornerOut
        return switch corner {
        case .topLeading: CGSize(width: -out, height: -out)
        case .topTrailing: CGSize(width: out, height: -out)
        case .bottomLeading: CGSize(width: -out, height: out)
        case .bottomTrailing: CGSize(width: out, height: out)
        }
    }

}

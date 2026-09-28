import SwiftUI

/// 反應三選一的臉（稿 `D0tWa`／`q9wdwF`／`M4R2io`：lucide `smile`／`meh`／`frown`）。SF Symbols 只有
/// `face.smiling`，沒有「普通」「不愛吃」兩張臉；三張用同一套 24 格線稿幾何自畫（lucide 原始座標、
/// stroke 2、圓端點），三個選項才是同一個筆觸家族。尺寸由呼叫端的 `appIconFrame` 決定（跟 Dynamic Type
/// 長大），線寬按比例縮放。
struct FoodReactionIcon: View {
    let reaction: FoodReaction

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / 24
            FaceShape(reaction: reaction)
                .stroke(style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    private struct FaceShape: Shape {
        let reaction: FoodReaction

        func path(in rect: CGRect) -> Path {
            let scale = min(rect.width, rect.height) / 24
            func point(_ gridX: CGFloat, _ gridY: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + gridX * scale, y: rect.minY + gridY * scale)
            }
            var path = Path()
            path.addEllipse(in: CGRect(origin: point(2, 2), size: CGSize(width: 20 * scale, height: 20 * scale)))
            for eyeX: CGFloat in [9, 15] {
                path.move(to: point(eyeX, 9))
                path.addLine(to: point(eyeX + 0.01, 9))
            }
            switch reaction {
            case .liked:
                path.move(to: point(8, 14))
                path.addQuadCurve(to: point(16, 14), control: point(12, 18))
            case .neutral:
                path.move(to: point(8, 15))
                path.addLine(to: point(16, 15))
            case .disliked:
                path.move(to: point(8, 16))
                path.addQuadCurve(to: point(16, 16), control: point(12, 12))
            }
            return path
        }
    }
}

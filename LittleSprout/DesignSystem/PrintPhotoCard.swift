import SwiftUI

/// 「沖印品」母題（LS-46 三個記憶點之一）：一張家庭照片先變成一張有白邊、被角托托在台紙上的
/// 相片，不是單純的底圖或卡片。全 app 共用同一套規則（Handoff Notes「角托三段規則」／
/// 「照片」段）。
///
/// 設計稿的照片素材（`hero-grandma.png` 等）是待審核的人像 placeholder，不進 Asset Catalog
/// （環境規約）——這裡改用 SF Symbol 縮圖占位，角托／白邊／染料池等版式規則原樣實作。
struct PrintPhotoCard: View {
    var photoHeight: CGFloat = 190
    var cornerSize: CGFloat = 26
    var mountPoolOpacity: MountPoolOpacity = .welcome
    var showsImprint = true
    var accessibilityLabel: String = "家庭照片"

    struct MountPoolOpacity {
        let topLeading: Double
        let topTrailing: Double
        let bottomLeading: Double
        let bottomTrailing: Double

        static let welcome = MountPoolOpacity(
            topLeading: 0.494, topTrailing: 0.288, bottomLeading: 0.36, bottomTrailing: 0.236
        )
        static let iPad = MountPoolOpacity(
            topLeading: 0.418, topTrailing: 0.207, bottomLeading: 0.132, bottomTrailing: 0.03
        )
    }

    var body: some View {
        VStack(spacing: 7) {
            photo
            if showsImprint {
                imprintRow
            }
        }
        .padding(.top, AppSpacing.printEdge)
        .padding(.horizontal, AppSpacing.printEdge)
        .padding(.bottom, AppSpacing.printEdgeBottom)
        .background(Color.lsPrintPaper)
        .background(mountPoolGlow)
        .overlay(PhotoCornerOverlay(size: cornerSize))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(imprintAccessibilityLabel)
        .accessibilityAddTraits(.isImage)
    }

    private var photo: some View {
        ZStack {
            Color.lsSurface2
            Image(systemName: "person.2.fill")
                .font(.system(size: photoHeight * 0.4))
                .foregroundStyle(Color.lsTextSecondary.opacity(0.5))
            Color.lsPhotoDim
        }
        .frame(height: photoHeight)
        .clipped()
    }

    private var imprintRow: some View {
        Text("LITTLE SPROUT")
            .font(.system(size: 12))
            .tracking(3.5)
            .foregroundStyle(Color.lsPrintInkSecondary)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    /// Lab Imprint 不吃 Dynamic Type、只印品牌名，併入相片 alt 尾段而不是留一個獨立、
    /// 系統字級縮不了的 VoiceOver 節點（Handoff Notes 通用節「字級」段的二選一規則）。
    private var imprintAccessibilityLabel: String {
        showsImprint ? "\(accessibilityLabel)（相紙邊緣印著 LITTLE SPROUT）" : accessibilityLabel
    }

    private var mountPoolGlow: some View {
        GeometryReader { proxy in
            let diameter = cornerSize * 6
            ZStack {
                glow(diameter: diameter, opacity: mountPoolOpacity.topLeading)
                    .position(x: 0, y: 0)
                glow(diameter: diameter, opacity: mountPoolOpacity.topTrailing)
                    .position(x: proxy.size.width, y: 0)
                glow(diameter: diameter, opacity: mountPoolOpacity.bottomLeading)
                    .position(x: 0, y: proxy.size.height)
                glow(diameter: diameter, opacity: mountPoolOpacity.bottomTrailing)
                    .position(x: proxy.size.width, y: proxy.size.height)
            }
        }
    }

    private func glow(diameter: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.lsMountPool.opacity(opacity), Color.lsMountPoolFade],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
    }
}

#Preview {
    PrintPhotoCard()
        .padding()
}

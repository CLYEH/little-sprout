import SwiftUI

/// 「沖印品」母題（LS-46 三個記憶點之一）：一張家庭照片先變成一張有白邊、被角托托在台紙上的
/// 相片，不是單純的底圖或卡片。全 app 共用同一套規則（Handoff Notes「角托三段規則」／
/// 「照片」段）。
///
/// LS-101 point 4：封面照片改用 `HeroGrandma` 資產（`design/hero-grandma.png` 壓成長邊
/// ≤1024px、品質 ~80 的 JPEG，深色模式沿用同一張、靠 `lsPhotoDim` 疊層變暗，不是換圖）。
/// `imageName` 給 nil 時退回 SF Symbol 縮圖占位，讓既有 Preview／未來未帶真實照片的呼叫端
/// 不必跟著改。
struct PrintPhotoCard: View {
    var photoHeight: CGFloat = 190
    var cornerSize: CGFloat = 26
    var mountPoolOpacity: MountPoolOpacity = .welcome
    var showsImprint = true
    var imageName: String?
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
        // LS-98 QA1 FAIL 修正：`.background` 鏈越晚呼叫、疊層越底。改之前 paper 先呼叫、
        // glow 後呼叫，於是不透明台紙蓋在染料池「前面」把它整片蓋住（QA1 四角取樣完全看不到
        // 染料池）。正確順序是台紙最底、染料池疊在台紙之上、照片與壓印行在最前——所以 glow
        // 這行要寫在 paper 之前（先呼叫的落在後呼叫的之上）。
        .background(mountPoolGlow.clipped())
        .background(Color.lsPrintPaper)
        .overlay(PhotoCornerOverlay(size: cornerSize))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(imprintAccessibilityLabel)
        .accessibilityAddTraits(.isImage)
    }

    private var photo: some View {
        ZStack {
            Color.lsSurface2
            if let imageName {
                Image(imageName)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.2.fill")
                    .font(.system(size: photoHeight * 0.4))
                    .foregroundStyle(Color.lsTextSecondary.opacity(0.5))
            }
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

import SwiftUI

/// `CreateChildView`（LS-113 / 08）頭像欄的沖印品母題（`design/littlesprout.pen`
/// `z4C4f`/`wrX2m`）：印相罩＋角托＋壓印行，相片區塊沒選圖時是「新增照片」佔位（相機圖示＋
/// 文字），選了圖之後（LS-169：`pickedImage` 非 nil）顯示本地預覽——裁方成正方形是上傳前
/// 才做的事（`AvatarImageProcessor`），這裡預覽用 `.scaledToFill()` + `.clipped()` 模擬
/// 「選圖後大概會長怎樣」，不必等真正裁完。壓印行顯示即時姓名預覽（空欄位時退回單一空白，
/// 撐住行高，同 `CreateFamilyView.FamilyPreviewCard` 的 `content:" "` 慣例）。與
/// `PrintPhotoCard` 結構相同但相片內容／壓印文字皆不同，未重用該元件（`PrintPhotoCard`
/// 壓印行固定印 "LITTLE SPROUT"，唯一出現地是歡迎頁家族，見 `little-sprout-brand` skill
/// 進場條件④）——這裡另建一份小型、僅本畫面使用的版本。
///
/// 從 `CreateChildView.swift` 拆出獨立檔案（LS-169）：加完 `PhotosPicker` 相關邏輯後那支
/// 檔案超過 SwiftLint `file_length` 上限，理由同 `DiaryComposerStorePublishRetryTests`
/// 從 `DiaryComposerStorePublishTests` 拆分（見該檔文件註解）——`CreateChildView` 是本檔
/// 唯一呼叫端，因此不再標 `private`（跨檔案要能引用），但仍不對外公開任何 API 意圖。
struct AvatarPrintCard: View {
    let name: String
    var photoHeight: CGFloat = 88
    var cornerSize: CGFloat = 26
    var pickedImage: UIImage?

    /// LS-67 R3 F24：08/08c 染料池四角 opacity（TL.429 TR.275 BL.367 BR.245）。
    private static let mountPoolOpacity = PrintPhotoCard.MountPoolOpacity(
        topLeading: 0.429, topTrailing: 0.275, bottomLeading: 0.367, bottomTrailing: 0.245
    )

    var body: some View {
        VStack(spacing: 7) {
            photoWrap
            imprintRow
        }
        .padding(.top, AppSpacing.printEdge)
        .padding(.horizontal, AppSpacing.printEdge)
        .padding(.bottom, AppSpacing.printEdgeBottom)
        .background(mountPoolGlow.clipped())
        .background(Color.lsPrintPaper)
        .overlay(PhotoCornerOverlay(size: cornerSize))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        pickedImage == nil ? "新增寶貝照片，目前尚未選擇" : "新增寶貝照片，已選擇一張照片，點一下可以換一張"
    }

    @ViewBuilder
    private var photoWrap: some View {
        if let pickedImage {
            Image(uiImage: pickedImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: photoHeight)
                .clipped()
        } else {
            VStack(spacing: AppSpacing.label) {
                Image(systemName: "camera")
                    .appIconFrame(.large)
                    .foregroundStyle(Color.lsTextSecondary)
                Text("點這裡新增照片")
                    .appFont(.note, weight: .semibold)
                    .foregroundStyle(Color.lsTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: photoHeight)
            .background(Color.lsSurface2)
        }
    }

    private var imprintRow: some View {
        Text(displayName)
            .appFont(.lead, weight: .semibold)
            .foregroundStyle(Color.lsPrintInk)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? " " : trimmed
    }

    private var mountPoolGlow: some View {
        GeometryReader { proxy in
            let diameter = cornerSize * 6
            ZStack {
                glow(diameter: diameter, opacity: Self.mountPoolOpacity.topLeading)
                    .position(x: 0, y: 0)
                glow(diameter: diameter, opacity: Self.mountPoolOpacity.topTrailing)
                    .position(x: proxy.size.width, y: 0)
                glow(diameter: diameter, opacity: Self.mountPoolOpacity.bottomLeading)
                    .position(x: 0, y: proxy.size.height)
                glow(diameter: diameter, opacity: Self.mountPoolOpacity.bottomTrailing)
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

#if DEBUG
#Preview {
    VStack(spacing: 16) {
        AvatarPrintCard(name: "陳小安")
        AvatarPrintCard(name: "")
    }
    .padding()
}
#endif

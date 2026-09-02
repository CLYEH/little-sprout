import SwiftUI

/// 疊在照片／縮圖上的影片時長徽章（`cmp/Card Photo` 稿面節點 `Video Badge`，
/// `design/littlesprout.pen` frame `xrCoj`／`sIJPp`，2026-09-03 讀稿核對）——播放圖示＋
/// 「影片」（尚未讀到時長／縮圖列不查）或「影片 M:SS」（讀到時長）。
///
/// merge-review `443ec21a` M1：稿面規格是**固定 12pt、不吃 Dynamic Type**（同
/// `PrintPhotoCard.imprintRow` 的 `fs-imprint` 一級，見 `Typography.swift` 檔頭註解「那是
/// 唯一不吃 Dynamic Type 的一級」）——AX3 使用者改由呼叫端的 accessibility label 取得完整
/// 資訊（`PhotoCardView` 既有的 `.accessibilityHidden(true)` 慣例），視覺徽章本身不需要、
/// 也不該隨字級放大，放大只會讓本來就窄的縮圖格更容易溢出。
///
/// 稿面量到的規格（`Video Badge` frame，`resolveVariables:false` 讀到的是 `$sp-tight`／
/// `$radius-full`／`$on-photo` 這些既有 token，只有 fill／padding 垂直值是稿面自己的字面值）：
/// - `fill: #2B141CBF` ＝ `$text-primary`（`print-ink`，同一個十六進位值）疊 75%
///   （`0xBF / 255 ≈ 0.749`）——不是黑色，是印墨色。
/// - `padding: [2, "$sp-tight"]`（垂直 2、水平 `AppSpacing.tight`＝6）、`gap: "$sp-tight"`
///   （圖示與文字間距）、`cornerRadius: "$radius-full"`（＝ `Capsule()`）。
/// - `Play Icon` 12×12、`Duration Label` `fontSize: 12`／`fontWeight: 700`。
///
/// fix/LS-130-video-badge-fallback：從 `PhotoCardView` 抽成共用元件，讓 `DiaryCardView`
/// 的附照預覽縮圖也能用同一套樣式——修 QA R2 FAIL（`a999c9af`）：無縮圖舊影片在時間軸日記卡
/// 的附照預覽完全沒有任何徽章。R2（`443ec21a`）：原本沿用 `.appFont(.note)`（17pt，會隨
/// Dynamic Type 再放大）＋錯誤的顏色／padding，在 ~99pt 的日記卡預覽格裡換行成兩行、右緣
/// 畫出卡片邊界——這裡改成稿面規格的固定 12pt＋正確 padding／顏色／圖示，`PhotoCardView`／
/// `DiaryCardView` 兩處呼叫端共用同一份實作，一次修好。純樣式元件，不含定位——呼叫端決定
/// 要貼在卡片的哪個角落、要不要 `.accessibilityHidden`。
struct VideoDurationBadge: View {
    private static let fontSize: CGFloat = 12
    private static let iconSize: CGFloat = 12
    private static let verticalPadding: CGFloat = 2

    let duration: TimeInterval?

    var body: some View {
        HStack(spacing: AppSpacing.tight) {
            Image(systemName: "play.fill")
                .font(.system(size: Self.fontSize * 0.7))
                .frame(width: Self.iconSize, height: Self.iconSize)
            Text(VideoDurationFormat.badgeText(duration: duration))
                .font(.system(size: Self.fontSize, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.lsOnPhoto)
        .padding(.horizontal, AppSpacing.tight)
        .padding(.vertical, Self.verticalPadding)
        .background(Color.lsTextPrimary.opacity(0.75), in: Capsule())
        // R2 二輪自測發現：貼在 ~99pt 的日記卡預覽格時，就算 12pt 也會被外層
        // `HStack { badge; Spacer(minLength: 0) }` 的寬度提案擠壓、`Text` 用 `.lineLimit(1)`
        // 的預設收縮行為把「影片 12:34」截斷成「影片 12:…」（accessibility value 仍是完整
        // 字串，`app.staticTexts["影片 12:34"]` 照樣找得到——這正是「a11y tree 看不到像素
        // 問題」的另一種樣貌，這次是「找得到元件但畫面上被截斷」，不是「量不到」）。
        // `.fixedSize()` 強制整顆徽章用自己的 ideal size 排版，不接受外層擠壓；真的放不下
        // 時交給 `DiaryCardView` 已經補上的 `.clipShape`（外層容器）硬裁，而不是這裡悄悄
        // 截斷文字——硬裁在視覺上比「看起來完整但其實斷詞」更誠實。
        .fixedSize()
    }
}

#Preview {
    ZStack(alignment: .bottomLeading) {
        Color.gray
        VideoDurationBadge(duration: 68)
            .padding(AppSpacing.label)
    }
    .frame(width: 220, height: 140)
}

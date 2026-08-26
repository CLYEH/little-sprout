import SwiftUI

/// 設計語言 v3.3 的字級 token（Tokens 板「③ 字級」）。數值是 `size`（一般字級）的基準 pt；
/// `relativeTo` 決定 Dynamic Type 怎麼縮放這個基準值（AX3 下大致對齊 Tokens 板列的 AX3 值，
/// 但不逐一寫死——見 Handoff Notes 通用節「工具邊界」：SwiftUI 端用 `@ScaledMetric`／Dynamic
/// Type 對應，不照抄 .pen 稿面的硬值）。
///
/// `fs-imprint`（12pt，沖印廠牌壓印字）刻意不在這裡：那是唯一不吃 Dynamic Type 的一級
/// （Handoff Notes 通用節），直接用 `.font(.system(size: 12))` 寫死。
enum AppFontToken {
    /// 34pt，畫面標題，每畫面最多 1 個。
    case display
    /// 22pt，唯一主卡或區塊標題。
    case lead
    /// 17pt，正文／按鈕標籤／欄位值／清單列。
    case body
    /// 17pt，與 body 同值但語意上一定伴隨狀態色或狀態圖示。
    case note
    /// 13pt，法務行／已用大字呈現過的欄位微標籤／純時間戳。
    case meta
    /// 36pt，OTP 六格數字（`.system(size:).monospacedDigit()`，見 `appNumericFont`；
    /// review comment `78b4455c` major A：Courier Prime 從未真的在 bundle 裡，且 `Font.custom(_:size:)`
    /// 會對 `@ScaledMetric` 已縮放過的 size 再依 body text style 縮放一次，雙重縮放）。
    case otp
    /// 60pt，07 邀請家人展示用邀請碼（`$fs-code`，design/littlesprout.pen variables；同
    /// `.otp` 一樣走系統字體＋`appNumericFont`，不是 Courier Prime——理由同 `.otp` 註解）。
    case code

    var size: CGFloat {
        switch self {
        case .display: 34
        case .lead: 22
        case .body, .note: 17
        case .meta: 13
        case .otp: 36
        case .code: 60
        }
    }

    var relativeStyle: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .lead: .title2
        case .body, .note: .body
        case .meta: .footnote
        case .otp, .code: .largeTitle
        }
    }

    /// R1 F5：`.code` 走 `.largeTitle` 曲線在 AX3 會長到 ~92pt（60 × 1.53），但
    /// `design/littlesprout.pen` variables 明確給了兩檔——`fs-code` default 60／AX3 72，
    /// 刻意只讓它長 1.2×，不是照系統曲線外插。72pt 是這個 token 的硬上限；`nil` 表示沿用
    /// 系統 Dynamic Type 曲線，不設上限（其餘 token 都不需要，包含只差 6% 的 `.otp`）。
    var maxScaledSize: CGFloat? {
        switch self {
        case .code: 72
        case .display, .lead, .body, .note, .meta, .otp: nil
        }
    }

    /// 供 `ScaledFontModifier` 套用，也讓測試不必建立 View／注入 Dynamic Type 環境就能驗證
    /// 上限邏輯——`@ScaledMetric` 只在 View body 內才會依環境算出實際值，這裡把「算出來的值
    /// 要不要夾住」拆成一個跟環境無關的純函式。
    static func clampedSize(_ scaledSize: CGFloat, maxScaledSize: CGFloat?) -> CGFloat {
        guard let maxScaledSize else { return scaledSize }
        return min(scaledSize, maxScaledSize)
    }
}

private struct ScaledFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool
    let maxScaledSize: CGFloat?

    init(token: AppFontToken, weight: Font.Weight, design: Font.Design, monospacedDigit: Bool) {
        _size = ScaledMetric(wrappedValue: token.size, relativeTo: token.relativeStyle)
        self.weight = weight
        self.design = design
        self.monospacedDigit = monospacedDigit
        self.maxScaledSize = token.maxScaledSize
    }

    func body(content: Content) -> some View {
        let clampedSize = AppFontToken.clampedSize(size, maxScaledSize: maxScaledSize)
        let font = Font.system(size: clampedSize, weight: weight, design: design)
        content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    /// 套用設計語言字級 token，自動隨 Dynamic Type 縮放（不寫死 pt）。
    func appFont(
        _ token: AppFontToken,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(ScaledFontModifier(token: token, weight: weight, design: design, monospacedDigit: false))
    }

    /// OTP／邀請碼展示級距數字專用：系統字體＋`.monospacedDigit()`，走 `AppFontToken.otp`／
    /// `.lead` 這類 ≥36pt 的 token（review comment `78b4455c` major A：不再走 `Font.custom`，見 `.otp` case
    /// 註解——`Font.custom(_:size:)` 對已縮放過的 size 會再依 body text style 縮放一次）。
    func appNumericFont(_ token: AppFontToken, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFontModifier(token: token, weight: weight, design: .default, monospacedDigit: true))
    }
}

/// icon 尺寸 token（Tokens 板「⑤ 尺寸與圓角」）。Pencil 的 width/height 對所有節點型別都
/// 靜默丟棄 `$variable`，稿面上是硬寫值；但 SwiftUI 端沒有這個限制，一律用
/// `@ScaledMetric` 讓 icon 跟著 Dynamic Type 長大（Handoff Notes 通用節「工具邊界」）。
enum AppIconToken {
    case small
    case medium
    case large
    case apple
    case google

    var size: CGFloat {
        switch self {
        case .small: 18
        case .medium: 22
        case .large: 26
        case .apple: 24
        case .google: 20
        }
    }
}

extension View {
    func appIconFrame(_ token: AppIconToken) -> some View {
        modifier(ScaledIconFrameModifier(token: token))
    }
}

private struct ScaledIconFrameModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat

    init(token: AppIconToken) {
        _size = ScaledMetric(wrappedValue: token.size, relativeTo: .body)
    }

    func body(content: Content) -> some View {
        content.frame(width: size, height: size)
    }
}

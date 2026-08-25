import SwiftUI

/// 設計語言 v3.3（`design/littlesprout.pen` Tokens 板）色彩 token，對應 Asset Catalog 的
/// 同名 Color Set（`Assets.xcassets`）。全部走 Any/Dark 兩欄，不寫死 hex——色值本身只在
/// Asset Catalog 裡登記一次（見 `.claude/evidence/LS-17/spec/tokens.json` 對照表）。
///
/// `print-ink`／`print-ink-secondary` 是設計刻意的例外：Color Set 只登記一份數值（Any），
/// 不隨深色模式反轉（LS-46 R11 進場條件②「紙永遠是淺表面、墨永遠是深色」）。
extension Color {
    static let lsAccent = Color("accent")
    static let lsAppleBackground = Color("apple-bg")
    static let lsAppleForeground = Color("apple-fg")
    static let lsBackground = Color("bg")
    static let lsBackgroundLit = Color("bg-lit")
    static let lsBorder = Color("border")
    static let lsControlLine = Color("control-line")
    static let lsCornerFold = Color("corner-fold")
    static let lsDanger = Color("danger")
    static let lsGoogleBackground = Color("google-bg")
    static let lsGoogleForeground = Color("google-fg")
    static let lsGoogleLine = Color("google-line")
    static let lsHomeIndicator = Color("home-indicator")
    static let lsMountPool = Color("mount-pool")
    static let lsMountPoolFade = Color("mount-pool-0")
    static let lsOnAccent = Color("on-accent")
    static let lsOnPhoto = Color("on-photo")
    static let lsPaperEdge = Color("paper-edge")
    static let lsPaperShadow = Color("paper-shadow")
    static let lsPhotoCorner = Color("photo-corner")
    static let lsPhotoDim = Color("photo-dim")
    static let lsPrintInk = Color("print-ink")
    static let lsPrintInkSecondary = Color("print-ink-secondary")
    static let lsPrintPaper = Color("print-paper")
    static let lsSurface = Color("surface")
    static let lsSurface2 = Color("surface-2")
    static let lsTextPrimary = Color("text-primary")
    static let lsTextSecondary = Color("text-secondary")
}

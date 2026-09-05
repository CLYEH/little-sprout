#if DEBUG
import SwiftUI

/// LS-191：`LegalDocumentSheet` harness host，從 `TapTargetGateHarness.swift` 拆出獨立檔案
/// ——同 `TapTargetGateHarness+UploadQueue.swift`（LS-167）的既有先例：那支檔案疊上新 case
/// 後會超過 SwiftLint `file_length` 上限。
extension TapTargetGateHarness {
    /// `LegalDocumentSheet` 沒有免登入即可到達的產品入口（歡迎頁連結才會開它）——同
    /// `uploadQueueSheetHost` 的既有作法，用常駐 `.sheet(isPresented: .constant(true))`
    /// 直接把 sheet 頂出來，固定顯示《使用條款》。
    @MainActor
    @ViewBuilder
    static var legalDocumentSheetHost: some View {
        Color.lsBackground
            .sheet(isPresented: .constant(true)) {
                LegalDocumentSheet(kind: .termsOfService)
            }
    }

    /// R4（merge-review R3 `889164c6` F1）：`debugForcedPadCardWidth: 320` 強制走 iPad
    /// 自適應內距分支＋把卡寬鎖在 320pt——不需要真的是 iPad 裝置就能重現／釘住「量到的寬度
    /// 被 `PreferenceKey` 預設值蓋掉」這個 wiring 缺陷，**在 iPhone 專屬機上就能跑**（同
    /// reviewer 建議）。`UploadQueueSheetView` 常駐 sheet 的既有作法。
    @MainActor
    @ViewBuilder
    static var legalDocumentNarrowContainerHost: some View {
        Color.lsBackground
            .sheet(isPresented: .constant(true)) {
                LegalDocumentSheet(kind: .termsOfService, debugForcedPadCardWidth: 320)
            }
    }
}
#endif

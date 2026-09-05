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
}
#endif

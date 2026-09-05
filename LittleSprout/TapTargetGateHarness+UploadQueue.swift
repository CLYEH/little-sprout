#if DEBUG
import SwiftUI

/// LS-167：`UploadQueueSheetView` 兩支 harness host，從 `TapTargetGateHarness.swift` 拆出
/// 獨立檔案——merge-review 解 LS-164 合併衝突後那支檔案再度超過 SwiftLint `file_length`
/// 上限，理由同 `TapTargetGateHarness+Albums.swift`（LS-165）的既有先例。
///
/// 兩支 host 都不能標 `private`（Swift 的 `private` 以檔案為界，跨檔案的 `extension` 存取
/// 不到）——同 `TapTargetGateHarness+Albums.swift` 的既有作法，改用預設（internal）存取
/// 層級，範圍仍只在本 module 內，`TapTargetGateHarness.hostView(for:)` 才呼叫得到。
extension TapTargetGateHarness {
    /// LS-167：`UploadQueueSheetView` 沒有真正的入口畫面（相簿詳情「加入照片」留給 LS-166），
    /// 用一個常駐 `.sheet(isPresented: .constant(true))` 直接把 sheet 頂出來，同
    /// `UploadQueueStore.previewSample()` 的代表性樣本（`#Preview` 也用同一份）。
    @MainActor
    @ViewBuilder
    static var uploadQueueSheetHost: some View {
        Color.lsBackground
            .sheet(isPresented: .constant(true)) {
                UploadQueueSheetView(store: .previewSample())
            }
    }

    /// merge-review R3 M1：生產「常態」樣本（無失敗、無續傳橫幅）——見
    /// `UploadQueueStore.previewNormalSample()` 文件註解。
    @MainActor
    @ViewBuilder
    static var uploadQueueSheetNormalHost: some View {
        Color.lsBackground
            .sheet(isPresented: .constant(true)) {
                UploadQueueSheetView(store: .previewNormalSample())
            }
    }
}
#endif

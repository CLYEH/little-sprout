import SwiftUI

// 拆檔理由：SwiftLint `file_length`。
#if DEBUG
#Preview("亮") {
    Color.clear.sheet(isPresented: .constant(true)) {
        UploadQueueSheetView(store: .previewSample())
    }
}

#Preview("深色") {
    Color.clear.sheet(isPresented: .constant(true)) {
        UploadQueueSheetView(store: .previewSample())
    }
    .preferredColorScheme(.dark)
}

#Preview("AX3") {
    Color.clear.sheet(isPresented: .constant(true)) {
        UploadQueueSheetView(store: .previewSample())
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}

extension UploadQueueStore {
    /// Preview／harness 共用的代表性樣本——涵蓋三群、LS002 置頂、有進度百分比與無進度百分比
    /// 兩種上傳中列，對應 `design/littlesprout.pen` `Q7HrnF`／`g8Q2W`「全部狀態展開」參考板。
    static func previewSample() -> UploadQueueStore {
        let store = UploadQueueStore(familyID: UUID(), mediaUploadService: PreviewMediaUploadService())
        // merge-review R2 F2：續傳橫幅在稿面上是真實會出現的狀態，但沒有任何一組樣本把它
        // 設成 `true` 過——preview／DEBUG harness／QA 截圖因此永遠看不到它，等於這條路徑
        // 沒有人真的驗過長什麼樣子。這裡固定開啟，讓它跟其他三群狀態一樣「看得到」。
        store.resumedFromInterruption = true
        let now = Date()
        func upload() -> PendingUpload {
            PendingUpload(
                kind: .photo(data: Data(), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            )
        }
        store.seedForPreview([
            .init(upload(), enqueuedAt: now.addingTimeInterval(-6 * 60), state: .failed(.quota)),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-4 * 60), state: .failed(.network)),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-5 * 60), state: .failed(.server)),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-1 * 60), state: .waiting),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-2 * 60), state: .uploading(progress: 0.42)),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-3 * 60), state: .completed),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-3.5 * 60), state: .completed)
        ])
        return store
    }

    /// merge-review R3 M1：生產「常態」樣本——沒有任何失敗（不觸發 `retryAllButton`）、沒有
    /// 續傳橫幅（`resumedFromInterruption` 維持預設 `false`）、`uploading` 也不帶百分比。
    /// `previewSample()` 為了一次展示所有狀態，`summarySection` 裡永遠至少有一個會撐滿寬度
    /// 的子元件（續傳橫幅或重試列），因此測不出「完全沒有撐寬元件時整塊被置中」這個 bug
    /// （reviewer 在生產常態下量到群標題 x=119.3，應為 24）。這個樣本刻意最小、最平常，
    /// 專門用來釘住這個回歸。
    static func previewNormalSample() -> UploadQueueStore {
        let store = UploadQueueStore(familyID: UUID(), mediaUploadService: PreviewMediaUploadService())
        let now = Date()
        func upload() -> PendingUpload {
            PendingUpload(
                kind: .photo(data: Data(), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            )
        }
        store.seedForPreview([
            .init(upload(), enqueuedAt: now.addingTimeInterval(-60), state: .waiting),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-30), state: .uploading(progress: nil)),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-180), state: .completed),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-200), state: .completed)
        ])
        return store
    }
}
#endif

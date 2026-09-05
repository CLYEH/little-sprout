import SwiftUI

/// 上傳佇列一列（`design/littlesprout.pen` `LS-142 / 16 上傳佇列`）：縮圖＋時間戳＋狀態文案。
///
/// **點擊目標**：「重試」／「查看儲存空間」在稿面上是行內小字（比對稿截圖，視覺高度遠小於
/// 44pt），但 `little-sprout-brand` skill 十條不可協商 #7（長輩硬約束，點擊 ≥44pt）沒有給
/// 「這顆看起來很小」的例外——`Pill` 那種唯讀展示元件才有明講的豁免（`BF6Cf`），這兩顆是
/// 真正會觸發動作的按鈕。視覺行高會比稿面截圖實測值高，這是刻意的取捨（規則衝突時遵守
/// #7，見 PR body「與稿差異」段），不是遺漏。
///
/// **merge-review R4**：R2/R3 用 `.frame(minHeight: 45)` 在本機量得 45pt，但 CI runner
/// （不同 Xcode／iOS SDK 組合）量到 43.2pt——`.frame(minHeight:)` 的實際生效高度會被文字
/// 內容的行高／基準線度量參與計算，同一份程式碼在不同系統字體 metrics 下可能有 <2pt 落差。
/// 改用 `minimumTapTargetHeight(_:alignment:)`：疊一個完全不含文字／圖示、單純
/// `Color.clear.frame(height:)` 的高度錨點進同一個 `ZStack`，靠 `ZStack` 的聯集尺寸規則
/// （最終尺寸＝各子項尺寸的聯集）保證整體至少這麼高——這個下限的計算是純幾何常數，不涉及
/// 任何字體度量，理論上跨 Xcode／iOS 版本一致。
struct UploadQueueRowView: View {
    let row: UploadQueueRow
    let thumbnail: UIImage?
    let onRetry: () -> Void
    let onViewStorage: () -> Void

    // merge-review R2 F5：對稿——縮圖 64pt，不是 48pt。
    private static let thumbnailSize: CGFloat = 64

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            thumbnailView
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                // `zejuQ`：時間戳記是這一列的主要識別，取代原本的檔名。
                Text(UploadQueueTimestampFormat.string(for: row.enqueuedAt))
                    .appNumericFont(.body, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                statusContent
            }
        }
    }

    private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                Color.lsSurface2
            }
        }
        .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch row.state {
        case .waiting:
            statusLine(icon: "clock", text: "等候上傳", color: Color.lsTextSecondary)
        case .uploading(let progress):
            uploadingContent(progress: progress)
        case .completed:
            // `ll8M7`：check→checkmark，「完成，中性色非 success」——刻意不用 `$success`。
            statusLine(icon: "checkmark", text: "已完成", color: Color.lsTextSecondary)
        case .failed(let reason):
            failedContent(reason: reason)
        }
    }

    private func statusLine(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: AppSpacing.tight) {
            Image(systemName: icon).appIconFrame(.small)
            Text(text).appFont(.note)
        }
        .foregroundStyle(color)
    }

    @ViewBuilder
    private func uploadingContent(progress: Double?) -> some View {
        if let progress {
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                progressBar(progress)
                Text("上傳中 · \(Int((progress * 100).rounded()))%")
                    .appNumericFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
        } else {
            // `UploadQueueStore` 檔頭「已知限制」：目前沒有位元組級進度可顯示——純文字，不編
            // 一個假數字或假動畫出來（Rule 11 fail loud：寧可少一個指示，不要顯示誤導的假
            // 進度）。
            Text("上傳中").appFont(.note).foregroundStyle(Color.lsTextSecondary)
        }
    }

    /// 純 `Capsule` 疊層畫的進度條，刻意不用 `ProgressView`——push-gate 實測 `ProgressView`
    /// （即使 `.accessibilityHidden(true)`）仍會被 `tap-target-check.sh` 的
    /// `app.buttons.allElementsBoundByIndex` 量到一個「表單控點」76×25pt 的獨立元件並判違規
    /// （`UIProgressView` 橋接出來的 accessibility 節點看來不完全聽 SwiftUI 這層修飾詞），
    /// 換成沒有任何內建 UIKit accessibility 語意的純圖形視圖就沒有這個問題。
    private func progressBar(_ progress: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.lsSurface2)
                Capsule().fill(Color.lsAccent)
                    .frame(width: proxy.size.width * CGFloat(min(max(progress, 0), 1)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func failedContent(reason: UploadFailureReason) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            HStack(alignment: .top, spacing: AppSpacing.tight) {
                Image(systemName: "exclamationmark.circle.fill").appIconFrame(.small)
                // merge-review R2 F5：對稿——失敗文案字重是 semibold（600），不是 regular。
                Text(reason.title).appFont(.note, weight: .semibold)
            }
            .foregroundStyle(Color.lsDanger)
            if reason.showsQuotaLink {
                // `hD3dH`：LS002 用「查看儲存空間」連結取代「重試」出路。`.contentShape(Rectangle())`
                // 缺這行時 hit-test／accessibility frame 只會貼著文字天然大小算（實測
                // 101.3×20.3pt，TAP-TARGET-FAIL）——同 `TapTargetGateHarness.swift`
                // `selfTestPaddingOutsideButton` 案例點名的同一個坑，`.frame` 必須配上這行
                // 才會真的決定 hit-test 形狀。
                Button(action: onViewStorage) {
                    Text("查看儲存空間").appFont(.note).underline()
                        .minimumTapTargetHeight(alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.lsTextPrimary)
            } else if reason.isRetryable {
                Button(action: onRetry) {
                    HStack(spacing: AppSpacing.tight) {
                        Image(systemName: "arrow.clockwise").appIconFrame(.small)
                        Text("重試").appFont(.note)
                    }
                    .minimumTapTargetHeight(alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.lsTextSecondary)
            }
        }
    }
}

/// merge-review R4：見 `UploadQueueRowView` 檔頭「merge-review R4」段——用純幾何的
/// `Color.clear` 高度錨點取代 `.frame(minHeight:)`，不依賴任何字體度量。`UploadQueueSheetView`
/// 的 footer／批次重試鈕也共用這個 helper（同一個 module，`internal` 存取層級即可，不必
/// 複製貼上兩份）。
extension View {
    func minimumTapTargetHeight(_ height: CGFloat = 45, alignment: Alignment = .center) -> some View {
        ZStack(alignment: alignment) {
            // `width: 0`：R4 第一版漏寫寬度，`Color` 沒有自然的「理想寬度」，`.frame(height:)`
            // 單獨出現時會貪心吃下父層願意提出的任何寬度——本機重跑撞見「查看儲存空間」／
            // 「重試」寬度從 101/58pt 暴衝到 282pt（撐滿整列可用寬度）。這裡只要一個「高度
            // 錨點」，寬度釘死 0，讓 ZStack 的寬度聯集完全交給 `self`（真正的內容）決定。
            // 高度用 45（不是 44）：拿掉字體度量依賴後理論上不會再有 CI/本機落差，但 ZStack
            // 聯集運算仍可能有極小的子像素捨入，多留 1pt 安全邊界。
            Color.clear.frame(width: 0, height: height)
            self
        }
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: AppSpacing.item) {
        UploadQueueRowView(
            row: UploadQueueRow(id: UUID(), enqueuedAt: Date(), state: .failed(.quota)),
            thumbnail: nil, onRetry: {}, onViewStorage: {}
        )
        UploadQueueRowView(
            row: UploadQueueRow(id: UUID(), enqueuedAt: Date(), state: .failed(.network)),
            thumbnail: nil, onRetry: {}, onViewStorage: {}
        )
        UploadQueueRowView(
            row: UploadQueueRow(id: UUID(), enqueuedAt: Date(), state: .uploading(progress: 0.42)),
            thumbnail: nil, onRetry: {}, onViewStorage: {}
        )
        UploadQueueRowView(
            row: UploadQueueRow(id: UUID(), enqueuedAt: Date(), state: .waiting),
            thumbnail: nil, onRetry: {}, onViewStorage: {}
        )
        UploadQueueRowView(
            row: UploadQueueRow(id: UUID(), enqueuedAt: Date(), state: .completed),
            thumbnail: nil, onRetry: {}, onViewStorage: {}
        )
    }
    .padding()
}
#endif

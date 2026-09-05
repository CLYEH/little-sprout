import SwiftUI

/// 上傳佇列一列（`design/littlesprout.pen` `LS-142 / 16 上傳佇列`）：縮圖＋時間戳＋狀態文案。
///
/// **點擊目標**：「重試」／「查看儲存空間」在稿面上是行內小字（比對稿截圖，視覺高度遠小於
/// 44pt），但 `little-sprout-brand` skill 十條不可協商 #7（長輩硬約束，點擊 ≥44pt）沒有給
/// 「這顆看起來很小」的例外——`Pill` 那種唯讀展示元件才有明講的豁免（`BF6Cf`），這兩顆是
/// 真正會觸發動作的按鈕。兩者都套 `.frame(minHeight: 45)`（不是剛好 44——push-gate 實測
/// `minHeight: 44` 配 `.contentShape(Rectangle())` 量出來的 hit-test frame 高度打印成
/// `44.0` 卻仍判定 `< 44`，猜測是子像素／scale factor 四捨五入產生的邊界值，留 1pt 安全
/// 邊界避免卡在浮點誤差上），視覺行高會比稿面截圖實測值高，這是刻意的取捨（規則衝突時遵守
/// #7，見 PR body「與稿差異」段），不是遺漏。
struct UploadQueueRowView: View {
    let row: UploadQueueRow
    let thumbnail: UIImage?
    let onRetry: () -> Void
    let onViewStorage: () -> Void

    private static let thumbnailSize: CGFloat = 48

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
                Text(reason.title).appFont(.note)
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
                        .frame(minHeight: 45, alignment: .leading)
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
                    .frame(minHeight: 45, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.lsTextSecondary)
            }
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

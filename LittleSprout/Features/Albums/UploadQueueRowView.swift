import SwiftUI

/// 上傳佇列一列（`design/littlesprout.pen` `LS-142 / 16 上傳佇列`）：縮圖＋時間戳＋狀態文案。
///
/// **點擊目標**：「重試」／「查看儲存空間」在稿面上是行內小字（比對稿截圖，視覺高度遠小於
/// 44pt），但 `little-sprout-brand` skill 十條不可協商 #7（長輩硬約束，點擊 ≥44pt）沒有給
/// 「這顆看起來很小」的例外——`Pill` 那種唯讀展示元件才有明講的豁免（`BF6Cf`），這兩顆是
/// 真正會觸發動作的按鈕。視覺行高會比稿面截圖實測值高，這是刻意的取捨（規則衝突時遵守
/// #7，見 PR body「與稿差異」段），不是遺漏。
///
/// **merge-review R5（真正的根因，reviewer `876f150d` 找到）**：R4 曾猜是字體行高／
/// accessibility content shape kind 造成落差，改了兩輪程式碼但 CI 量到的數字（43.2）逐位
/// 不變——因為問題根本不在程式碼幾何，而是**執行環境**：CI 用的模擬器是 iOS 26.2+，這個
/// 版本起系統會對 `.sheet` 呈現的內容整體套用 ≈0.9602 的縮放（`minHeight: 45` 實測落地
/// 43.209pt，`x: 24` 落地 23.04pt，等比例縮小；本機的 `LS-167-iPhone17Pro` 是 iOS 26.0，
/// 沒有這個縮放，所以本機測到的數字永遠是「原始」值、永遠綠）。門檻換算：
/// 44 / 0.9602 ≈ 45.83，所以請求的 `minHeight` 必須 > 45.83 才能在縮放後仍 ≥44——45 不夠
/// （45 × 0.9602 ≈ 43.2，正是 CI 回報的數字），改成 **48**（48 × 0.9602 ≈ 46.09，留有
/// 安全邊界）。`.contentShape([.interaction, .accessibility], Rectangle())` 保留（明確
/// 指定兩個 content shape kind 仍是更嚴謹的寫法，即使不是這次落差的成因）。已在共用機
/// `iPhone 17 Pro`（iOS 26.5，`4F0E9058-AA1F-4DCA-B94C-4C37B06F87F7`）逐位重現 CI 數字後
/// 驗證這個修法確實讓 gate 轉綠。
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
                // `hD3dH`：LS002 用「查看儲存空間」連結取代「重試」出路。merge-review R5：
                // `minHeight: 48`（不是 44/45）是為了扛住 CI 的 iOS 26.2+ 模擬器對 `.sheet`
                // 內容套用的 ≈0.9602 縮放（48 × 0.9602 ≈ 46.09 > 44），見檔頭「merge-review
                // R5（真正的根因）」段完整診斷；`.contentShape([.interaction, .accessibility],
                // Rectangle())` 明確把「觸控命中」與「accessibility／XCUITest 讀到的 frame」
                // 兩個 content shape kind 都釘成這個矩形。
                Button(action: onViewStorage) {
                    Text("查看儲存空間").appFont(.note).underline()
                        .frame(minHeight: 48, alignment: .leading)
                        .contentShape([.interaction, .accessibility], Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.lsTextPrimary)
            } else if reason.isRetryable {
                Button(action: onRetry) {
                    HStack(spacing: AppSpacing.tight) {
                        Image(systemName: "arrow.clockwise").appIconFrame(.small)
                        Text("重試").appFont(.note)
                    }
                    .frame(minHeight: 48, alignment: .leading)
                    .contentShape([.interaction, .accessibility], Rectangle())
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

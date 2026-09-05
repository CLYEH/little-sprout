import SwiftUI

/// 上傳佇列一列（`design/littlesprout.pen` `LS-142 / 16 上傳佇列`）：縮圖＋時間戳＋狀態文案。
///
/// **點擊目標**：「重試」／「查看儲存空間」在稿面上是行內小字（比對稿截圖，視覺高度遠小於
/// 44pt），但 `little-sprout-brand` skill 十條不可協商 #7（長輩硬約束，點擊 ≥44pt）沒有給
/// 「這顆看起來很小」的例外——`Pill` 那種唯讀展示元件才有明講的豁免（`BF6Cf`），這兩顆是
/// 真正會觸發動作的按鈕。視覺行高會比稿面截圖實測值高，這是刻意的取捨（規則衝突時遵守
/// #7，見 PR body「與稿差異」段），不是遺漏。
///
/// **merge-review R5（真正的根因）**：R4 猜測是字體行高參與 `.frame(minHeight:)` 的計算，
/// 改用 `Color.clear` 高度錨點疊 `ZStack`（純幾何、不含文字）——本機量到 45pt，push 後 CI
/// 仍量到跟 R2/R3 一模一樣的 43.2pt（三個數字到小數點後一位完全相同，跨兩份結構完全不同的
/// 實作），證明問題根本不在「用什麼幾何湊出 45pt 的 layout frame」。真正原因：
/// `.contentShape(Rectangle())` 預設只設定 `.interaction`（觸控命中）這個 content shape
/// kind，`XCUITest` 的 `element.frame` 讀的是 **accessibility** frame——本機這台 Xcode／
/// iOS 版本剛好讓 accessibility frame 也一併採用 layout frame（意外地「連帶生效」），CI 的
/// 版本組合則沒有這個連帶效應，accessibility frame 仍然貼著文字內容本身的天然大小算，跟
/// 外層疊了多少層透明 `Color.clear` 完全無關。改用
/// `.contentShape([.interaction, .accessibility], Rectangle())`——SwiftUI 讓你為不同用途
/// 分別指定 content shape，這裡明確兩個 kind 都設，不依賴任何隱含的連帶關係，不涉及字體
/// 度量，也不需要額外疊 `ZStack`。
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
                // `.frame(minHeight:)` 建立 layout frame，`.contentShape([.interaction,
                // .accessibility], Rectangle())` 明確把「觸控命中」與「accessibility／
                // XCUITest 讀到的 frame」兩個 content shape kind 都釘成這個矩形——只設
                // `.interaction`（`.contentShape(Rectangle())` 的預設行為）在某些 Xcode／
                // iOS 版本組合下不會連帶影響 accessibility frame，見檔頭「merge-review R5」
                // 段的完整診斷。
                Button(action: onViewStorage) {
                    Text("查看儲存空間").appFont(.note).underline()
                        .frame(minHeight: 45, alignment: .leading)
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
                    .frame(minHeight: 45, alignment: .leading)
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

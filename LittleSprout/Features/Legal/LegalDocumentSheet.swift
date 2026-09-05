import SwiftUI
import UIKit

/// LS-191（依 LS-133 稿 `EzJCV`／`O631mm`／`E27nKz`／`uQeV8`；Notes `pLLXi`）：法務文件
/// in-app 檢視 sheet。bundled markdown 全文捲動閱讀，Footer 關閉鈕釘底。歡迎頁《使用條款》
/// 《隱私權政策》連結改開這個 sheet（見 `WelcomeView`），取代原本跳出系統瀏覽器。
///
/// **Grabber 自畫，不用 `.presentationDragIndicator`**（LS-167 `UploadQueueSheetView` 同一
/// 理由的既有先例，見該檔文件註解）：系統 grabber 一啟用會被曝露成一個獨立的 accessibility
/// 元件（label「表單控點」，量到 76×25pt），被 `tap-target-check.sh` 判成 <44pt 違規——這是
/// Apple 系統繪製的控制項，沒有公開 API 能調整它的 hit-test 尺寸。改用稿面同款規格的自畫
/// `Capsule`（36×5pt，`$border`，`.accessibilityHidden(true)`）：純 `Shape` 不參與
/// accessibility tree，不會被量到；drag-to-dismiss 是系統行為，不受影響（稿面 Notes `H8h08`
/// 要求的下滑關閉手勢因此仍成立）。
///
/// **不重現稿面「露出比例」的靜態裁切戲法**：`.pen` 是靜態畫布，`clip:true` 固定高度容器是
/// 用來模擬「捲動中，未捲到底」的視覺效果（Notes `nl8ar`）；且稿面只節錄了全文開頭幾段
/// （Notes `Hj8oA`：「bundle markdown 是完整全文，App 內可正常捲動到底」）。這裡用真正的
/// `ScrollView` 承載**全文**——文字長度遠超過任何裝置可視高度，「還有更多可捲」的視覺提示
/// 是任何真實內容自然產生的效果，不需要另外計算裁切比例或复刻稿面高度數字（同 LS-167
/// `UploadQueueSheetView` 對「Rows Scroll Area」裁切戲法的既有處理方式：Rule 2 簡化，比
/// 稿面手法更簡單、行為更正確的等價實作）。
///
/// **iPad**：稿面 `uQeV8` 用置中卡片而非滿版 sheet，理由是 SwiftUI `.sheet()` 在 regular
/// width、未強制 `presentationDetents` 時的原生行為就是置中浮動 form sheet（系統行為，不是
/// 設計選擇——Notes `NzCXK`）。用 `.frame(width: 520)` 固定內容寬度（Notes `W0Umr`：R3 定案
/// 520＋內距 87.5，內容欄 345），讓 sheet 依內容尺寸置中呈現，不設 Grabber（置中卡片沒有下滑
/// 手勢慣例）。
///
/// **判斷用裝置 idiom，不用 `horizontalSizeClass`**（merge-review R1 `807855dc` F1）：R1 曾用
/// `@Environment(\.horizontalSizeClass) == .regular` 判斷，但**實測** `.sheet()` 的 form
/// sheet 呈現容器本身較窄（≈580pt），環境回報的 `horizontalSizeClass` 在 iPad 上恆為
/// `.compact`——量的是 presentation 容器，不是裝置。導致 regular 分支從未執行，iPad 上一路
/// 落回 iPhone 版面（見 R1 PR #326 review，reviewer 重新截圖量到 580×650pt、24.5pt 內距、
/// 仍有 Grabber）。改用 `UIDevice.current.userInterfaceIdiom == .pad`：量裝置本身，跟
/// presentation context 無關，且不需要更動 `LegalDocumentSheet(kind:)` 這個票文指定的 API
/// 形狀（呼叫端不用多傳一個 size class 參數）。
struct LegalDocumentSheet: View {
    let kind: LegalDocumentKind

    @Environment(\.dismiss) private var dismiss

    @State private var document: LegalMarkdownDocument?
    @State private var failedToLoad = false

    /// `$fs-body`(17) × lineHeight 1.7（Notes `PpgKA`）換算成 SwiftUI `.lineSpacing`
    /// （額外行距，不是行高倍率）：17 × (1.7 − 1) ≈ 12。
    private let bodyLineSpacing: CGFloat = 12
    /// R3 定案（Notes `W0Umr`）：520 寬卡片 − 內距 87.5×2 ＝ 345 內容欄，與 iPhone
    /// （`AppSpacing.screenPad` 24×2 於 393pt 裝置寬）算出的內容欄一致。
    private let iPadCardWidth: CGFloat = 520
    private let iPadCardPadding: CGFloat = 87.5

    private var isPadIdiom: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        Group {
            if let document {
                if isPadIdiom {
                    layout(for: document, horizontalPadding: iPadCardPadding, showsGrabber: false)
                        .frame(width: iPadCardWidth)
                        // R1 F1：iPad 分支不畫自畫 Grabber（`showsGrabber: false` 已涵蓋），
                        // 這裡額外明確隱藏系統拖曳把手——置中卡片沒有下滑手勢慣例，防止任何
                        // 系統預設行為意外冒出把手（reviewer 明確要求，雙重保險不嫌多）。
                        .presentationDragIndicator(.hidden)
                } else {
                    layout(for: document, horizontalPadding: AppSpacing.screenPad, showsGrabber: true)
                }
            } else if failedToLoad {
                loadErrorState
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.lsSurface)
            }
        }
        .onAppear(perform: loadIfNeeded)
    }

    private func loadIfNeeded() {
        guard document == nil, !failedToLoad else { return }
        guard let loaded = LegalMarkdownDocument.loadBundled(kind) else {
            failedToLoad = true
            return
        }
        document = loaded
    }

    // MARK: - 版面（iPhone 滿版 sheet／iPad 置中卡片共用同一份骨架，差異只在寬度與 Grabber）

    private func layout(
        for document: LegalMarkdownDocument, horizontalPadding: CGFloat, showsGrabber: Bool
    ) -> some View {
        VStack(spacing: 0) {
            if showsGrabber {
                grabber
            }
            head(for: document)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, AppSpacing.block)
            Rectangle().fill(Color.lsBorder).frame(height: 1)
                .padding(.top, AppSpacing.block)
            ScrollView {
                blockList(document.blocks)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, AppSpacing.block)
            }
        }
        .background(Color.lsSurface)
        .safeAreaInset(edge: .bottom) { footer(horizontalPadding: horizontalPadding) }
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.lsBorder)
            .frame(width: 36, height: 5)
            .padding(.top, AppSpacing.block)
            .accessibilityHidden(true)
    }

    private func head(for document: LegalMarkdownDocument) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text(kind.title)
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text(document.metaLine)
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(horizontalPadding: CGFloat) -> some View {
        SecondaryButton(icon: "xmark", title: "關閉") { dismiss() }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, AppSpacing.item)
            .background(Color.lsSurface)
    }

    private func blockList(_ blocks: [LegalMarkdownBlock]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: LegalMarkdownBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
        case .paragraph(let text):
            bodyText(text)
        case .listItem(let text):
            HStack(alignment: .top, spacing: AppSpacing.label) {
                Text("•").appFont(.body).foregroundStyle(Color.lsTextPrimary)
                bodyText(text)
            }
        case .tableRow(let text, let isHeader):
            Text(text)
                .appFont(.body, weight: isHeader ? .bold : .regular)
                .foregroundStyle(Color.lsTextPrimary)
                .lineSpacing(bodyLineSpacing)
        }
    }

    private func bodyText(_ text: AttributedString) -> some View {
        Text(text)
            .appFont(.body)
            .foregroundStyle(Color.lsTextPrimary)
            .lineSpacing(bodyLineSpacing)
    }

    private var loadErrorState: some View {
        VStack(spacing: AppSpacing.label) {
            Text("無法載入內容")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("請關閉後重新開啟，或稍後再試一次。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
            SecondaryButton(icon: "xmark", title: "關閉") { dismiss() }
        }
        .padding(AppSpacing.screenPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.lsSurface)
    }
}

#if DEBUG
#Preview("使用條款") {
    Color.lsBackground
        .sheet(isPresented: .constant(true)) {
            LegalDocumentSheet(kind: .termsOfService)
        }
}

// 「隱私權政策 · iPad」預覽已移除：iPad 版面判斷改用 `UIDevice.current.userInterfaceIdiom`
// （R1 F1），Xcode Preview canvas 沒有能覆寫裝置 idiom 的 environment key——要預覽 iPad
// 版面請直接把 Preview 的目標裝置切到 iPad（Canvas 右側裝置選單），不是靠程式碼覆寫。
#endif

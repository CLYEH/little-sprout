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
/// 設計選擇——Notes `NzCXK`）。內容寬度上限 520（Notes `W0Umr`：R3 定案 520＋內距 87.5，內容欄
/// 345），讓 sheet 依內容尺寸置中呈現，不設 Grabber（置中卡片沒有下滑手勢慣例）。
///
/// **判斷用裝置 idiom，不用 `horizontalSizeClass`**（merge-review R1 `807855dc` F1）：R1 曾用
/// `@Environment(\.horizontalSizeClass) == .regular` 判斷，但**實測** `.sheet()` 的 form
/// sheet 呈現容器本身較窄（≈580pt），環境回報的 `horizontalSizeClass` 在 iPad 上恆為
/// `.compact`——量的是 presentation 容器，不是裝置。導致 regular 分支從未執行，iPad 上一路
/// 落回 iPhone 版面（見 R1 PR #326 review，reviewer 重新截圖量到 580×650pt、24.5pt 內距、
/// 仍有 Grabber）。改用 `UIDevice.current.userInterfaceIdiom == .pad`：量裝置本身，跟
/// presentation context 無關，且不需要更動 `LegalDocumentSheet(kind:)` 這個票文指定的 API
/// 形狀（呼叫端不用多傳一個 size class 參數）。
///
/// **系統 sheet 底色**（merge-review R2 `8305338b` M1）：只把 `Color.lsSurface` 鋪在 520pt
/// 內容上不夠——iPad 的系統 form sheet 本身還有約 580pt 寬、內容置中後左右各露出約 30pt 的
/// 系統預設底色（實測是平坦硬邊 `(243,245,242)`，比紙色更亮更綠，不是陰影或圓角造成的視覺
/// 誤差）。加 `.presentationBackground(Color.lsSurface)` 讓整張 form sheet 都是紙色，520
/// 內容置中其上，才真的等於稿面 `uQeV8` 那張整片粉卡。
///
/// **窄容器不裁字**（merge-review R2 `8305338b` M2）：專案是 universal
/// （`TARGETED_DEVICE_FAMILY "1,2"`）且未設 `UIRequiresFullScreen`，iPad Slide Over／分割
/// 視窗（呈現容器可窄至 ≈320pt）是可達狀態，此時 idiom 仍是 `.pad`。原本 `.frame(width: 520)`
/// 對呈現容器「要求」固定寬度而非「至多」，容器比 520 窄時內容會被容器邊界裁掉（例如標題
/// 「使用條款」被裁成「用條款」）。改用 `.frame(maxWidth: 520)`（容器比 520 寬時封頂在
/// 520，比 520 窄時允許收縮，永遠不會比容器本身更寬）；內距改用
/// `iPadHorizontalPadding`，靠 `.background(GeometryReader)` 量測卡片實際渲染寬度後動態夾在
/// `[24, 87.5]` 之間（純函式見 `Self.iPadCardAdaptivePadding`，回歸測試見
/// `LegalDocumentSheetLayoutTests`）——容器越窄，內距越小，內容永遠不超出容器邊界。
///
/// **R4 修正 `LegalDocumentSheetWidthKey` 的 wiring 缺陷**（merge-review R3 `889164c6`
/// F1）：R3 版的 `PreferenceKey` 用 `defaultValue = 520`＋`reduce { value = nextValue() }`
/// ——SwiftUI 對「沒有明確設 preference」的兄弟子樹一樣會用 `defaultValue` 參與 reduce，
/// `reduce` 只是單純覆寫成最後一筆看到的值，導致量到的真實寬度常被某個貢獻
/// `defaultValue`（520）的兄弟節點蓋掉。**實測**：320pt 窄容器 proxy 下畫面印出
/// `W=520.0 PAD=87.5`（內容欄只剩 145pt），不是設計要的 `W=320.0 PAD=24.0`（內容欄
/// 272pt）——iPad 全螢幕情境「看起來正確」純粹是因為預設值 520 剛好等於真值，量測機制
/// 本身從未真正生效（同 R1 F1 一樣的「寫了但不執行」失效型態）。改為
/// `defaultValue = 0`＋`reduce { value = max(value, nextValue()) }`：沒有明確設 preference
/// 的兄弟子樹貢獻 0（reduce 用 `max` 時必輸），真正量到的 `GeometryReader` 永遠是唯一非零
/// 貢獻者，`max` reduce 後一定是它勝出，不受樹狀走訪順序影響。`onPreferenceChange` 對應
/// 加 `guard $0 > 0` 忽略「還沒真的量到」的 0 讀數，不覆寫掉 `iPadMeasuredWidth` 的初始
/// 合理預設值（見下方 `iPadMeasuredWidth` 宣告）。
struct LegalDocumentSheet: View {
    let kind: LegalDocumentKind

    #if DEBUG
    /// R4（merge-review R3 `889164c6` F1）：測試專用覆寫，讓 harness／UITest 能在**任何裝置**
    /// （含 iPhone）強制走 iPad 自適應內距分支並指定一個窄容器寬度，藉此重現／釘住
    /// 「`GeometryReader` 量到的寬度被 `PreferenceKey` 預設值蓋掉」這類 wiring 缺陷——
    /// reviewer 指出既有 iPad 專屬 UITest 在全螢幕下量到的真寬剛好等於預設值 520，
    /// 對這個缺陷不敏感（`TapTargetGateHarness+Legal.swift`
    /// `legalDocumentNarrowContainerHost`／`LegalDocumentSheetUITests`
    /// `testNarrowContainerHost...` 使用）。只在 DEBUG 存在，`nil`（預設）時行為與正式
    /// 呼叫端（`WelcomeView`）完全相同，不影響 Release 組建。
    var debugForcedPadCardWidth: CGFloat?
    #endif

    @Environment(\.dismiss) private var dismiss

    @State private var document: LegalMarkdownDocument?
    @State private var failedToLoad = false
    /// R2 M2：`iPadCardWidth`（一般全螢幕情境下的卡寬）當測到真正寬度之前的預設值——這是
    /// **狀態初值**，跟下面 `LegalDocumentSheetWidthKey.defaultValue`（reduce 用的 0 哨兵值，
    /// 兩者用途不同）無關。R3 review 問過「首幀會不會閃」：一般全螢幕 iPad 情境下初值就是
    /// 真值，完全不閃；只有真的在窄容器（Slide Over）開啟這個畫面時，第一幀會先用 520 算出
    /// 87.5 內距，同一個 layout pass 內 `GeometryReader` 回報真實寬度後立刻更新——SwiftUI
    /// 通常在同一次 update cycle 內解完 preference 才真正呈現到螢幕，實務上量不到肉眼可見的
    /// 閃爍（沒有做逐幀擷取影片去量측，這裡誠實記錄成「理論上存在、目測未觀察到」，不誇稱
    /// 「保證不閃」）。
    @State private var iPadMeasuredWidth: CGFloat = 520

    /// `$fs-body`(17) × lineHeight 1.7（Notes `PpgKA`）換算成 SwiftUI `.lineSpacing`
    /// （額外行距，不是行高倍率）：17 × (1.7 − 1) ≈ 12。
    private let bodyLineSpacing: CGFloat = 12
    /// R3 定案（Notes `W0Umr`）：520 寬卡片 − 內距 87.5×2 ＝ 345 內容欄，與 iPhone
    /// （`AppSpacing.screenPad` 24×2 於 393pt 裝置寬）算出的內容欄一致。
    private var iPadCardWidth: CGFloat {
        #if DEBUG
        if let forced = debugForcedPadCardWidth { return forced }
        #endif
        return 520
    }
    private let iPadCardMaxPadding: CGFloat = 87.5
    private let iPadCardMinContentWidth: CGFloat = 345

    private var isPadIdiom: Bool {
        #if DEBUG
        if debugForcedPadCardWidth != nil { return true }
        #endif
        return UIDevice.current.userInterfaceIdiom == .pad
    }

    /// R2 M2：容器寬度→內距的純函式，方便脫離 View 直接單元測試（見
    /// `LegalDocumentSheetLayoutTests`）。容器 ≥ 520 時內距封頂在 `maxPadding`（87.5）；
    /// 容器 < `minContentWidth + minPadding×2`（393）時內距降到 `minPadding`（24）下限，
    /// 內容欄跟著收縮但保證至少留有這道最小呼吸間距。**下界前提**（merge-review R3 N1
    /// `889164c6`，誠實記錄不誇稱）：容器 < `minPadding×2`（48pt）時，`minPadding` 保底本身
    /// 會讓內距之和超過容器寬、內容欄變成負數——實務上不會有 48pt 的 sheet／裝置寬（iPad
    /// Slide Over 最小約 320pt），這個下界從未在真實情境出現，不需要額外處理。
    static func iPadCardAdaptivePadding(
        containerWidth: CGFloat, maxPadding: CGFloat, minContentWidth: CGFloat, minPadding: CGFloat
    ) -> CGFloat {
        let computed = (containerWidth - minContentWidth) / 2
        return min(maxPadding, max(minPadding, computed))
    }

    private var iPadHorizontalPadding: CGFloat {
        Self.iPadCardAdaptivePadding(
            containerWidth: iPadMeasuredWidth,
            maxPadding: iPadCardMaxPadding,
            minContentWidth: iPadCardMinContentWidth,
            minPadding: AppSpacing.screenPad
        )
    }

    var body: some View {
        Group {
            if let document {
                if isPadIdiom {
                    layout(for: document, horizontalPadding: iPadHorizontalPadding, showsGrabber: false)
                        .frame(maxWidth: iPadCardWidth)
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: LegalDocumentSheetWidthKey.self, value: proxy.size.width)
                            }
                        )
                        .onPreferenceChange(LegalDocumentSheetWidthKey.self) { newWidth in
                            // R4：0 是「沒有任何子樹真的量到」的哨兵值（見
                            // `LegalDocumentSheetWidthKey` 文件註解），忽略它，不要用它覆寫
                            // 掉已經算好的合理初值。
                            guard newWidth > 0 else { return }
                            iPadMeasuredWidth = newWidth
                        }
                        // R1 F1：iPad 分支不畫自畫 Grabber（`showsGrabber: false` 已涵蓋），
                        // 這裡額外明確隱藏系統拖曳把手——置中卡片沒有下滑手勢慣例，防止任何
                        // 系統預設行為意外冒出把手（reviewer 明確要求，雙重保險不嫌多）。
                        .presentationDragIndicator(.hidden)
                        // R2 M1：見上方文件註解「系統 sheet 底色」。
                        .presentationBackground(Color.lsSurface)
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

    /// merge-review R1 F4（PLAUSIBLE，`807855dc`）：改用 `LazyVStack`——ToS 111／隱私 156 個
    /// block 用 eager `VStack` 會在 sheet 開場一次建構＋量測全部 `Text`；只在可視範圍內按需
    /// 具現化，同 `TimelineView`／`AlbumsView` 對長列表的既有慣例（Rule 10）。粗略量測（重複
    /// 冷啟動含 app launch 開銷，雜訊大、量不出純 VStack 建構成本的乾淨數字）沒有找到決定性
    /// 訊號，但這是一個字的改動、零行為差異（Head／Footer 不在 ScrollView 內，不受影響），
    /// 照 reviewer 建議直接採用，不需要用「沒實測到變慢」當理由續用 eager 版本。
    private func blockList(_ blocks: [LegalMarkdownBlock]) -> some View {
        LazyVStack(alignment: .leading, spacing: AppSpacing.block) {
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
                // merge-review R1 F3：25／24 個節標題是全 app 最長純文字畫面的唯一導覽線索，
                // 補 heading trait 讓 VoiceOver 轉輪能跳段（同 TimelineView／AlbumsView 既有
                // 慣例）。
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            bodyText(text)
        case .listItem(let text, let marker):
            HStack(alignment: .top, spacing: AppSpacing.label) {
                Text(marker).appFont(.body).foregroundStyle(Color.lsTextPrimary)
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

/// R2 M2：`.background(GeometryReader)` 讀寬度不影響外層 layout 的標準寫法——`.background`
/// 依前景（`layout(...).frame(maxWidth:)`）已解出的大小塞入背景，GeometryReader 本身不會
/// 要求父層改給更大的空間，因此不影響 form sheet 依內容高度自動置中／調整大小的既有行為
/// （F1 靠的就是這個自動行為，見上方 struct 文件註解）。
///
/// **`defaultValue = 0`＋`reduce` 用 `max`**（R4，merge-review R3 `889164c6` F1）：SwiftUI
/// 對整棵視圖樹裡「沒有明確設這個 preference」的節點一樣會用 `defaultValue` 參與 reduce
/// （不是只有真的呼叫 `.preference(key:value:)` 的節點才算數）。R3 版用
/// `defaultValue = 520`＋`reduce { value = nextValue() }`（單純覆寫），若某個沒設 preference
/// 的兄弟節點在走訪順序中排在真正量測的 `GeometryReader`之後，它貢獻的 `defaultValue`
/// 就會把量到的真值蓋掉——這正是 R3 實測到「320pt 窄容器下仍量到 520」的根因。改成
/// `defaultValue = 0`＋`max` reduce：沒設 preference 的節點貢獻 0，在 `max` 語義下必輸給
/// 任何真正量到的正值，因此哪個節點先後走訪都不影響最終結果只會是「真正量到的最大值」。
private struct LegalDocumentSheetWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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

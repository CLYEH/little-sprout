import SwiftUI

/// 時間軸相簿卡（`cmp/Card Album`，LS-126 票文 Scope 1）——沖印品母題封面＋白邊壓印 Caption
/// （相簿名＋張數，LS-390）＋底部互動列（`InteractionRow`，LS-216）。
///
/// 純顯示元件，不含導覽：相簿畫面本身不在本票範圍（票文「不做」），這裡只顯示卡片本身，
/// 不掛 tap 動作。LS-216：`InteractionRow` 的三顆按鈕不落在卡片本體的 `.accessibilityElement`
/// 範圍內，見該型別文件註解與 `DiaryCardView` 同款處理。
struct AlbumCardView: View {
    let content: AlbumContent
    let timelineStore: TimelineStore
    /// LS-345 R2：只為了轉手給 `InteractionRow`／`LikersListSheet`——見該型別文件註解。
    let familyStore: FamilyStore
    /// LS-216：這本相簿的 id——`AlbumContent` 本身不帶 id（純顯示模型），理由同
    /// `DiaryCardView.refId` 文件註解。
    let refId: UUID
    var onOpenComments: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            PrintPhotoCard(
                photoHeight: 190,
                mountPoolOpacity: .card,
                showsImprint: false,
                remoteURL: content.cover?.signedURL,
                accessibilityLabel: content.title,
                imprintCaption: AnyView(caption)
            )
            // LS-390：標題進白邊（`cmp/Card Album` `bhroo` Imprint Row `IXmLN`）後，卡片本體
            // （照片＋Caption）念成一個元素、含張數；InteractionRow 三顆按鈕不落在範圍內（LS-216，
            // 見型別文件註解）。`.ignore`＋明確 label：不靠 combine 把照片 alt 與 Caption 各念一遍
            // （改前標題會念兩次），也不把 Caption 內的 U+2060／NBSP 折行字元交給 VoiceOver。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(content.title)，\(content.photoCount) 張相片")
            // LS-406（LS-390 R1 I1）：`.ignore` 會吃掉照片的 `.isImage`（改前 `.combine` 帶得上），有封面時補回、
            // VoiceOver 念「圖像」；占位圖（沒有封面）不加。判準是 `cover != nil`（有簽名 URL 就是有照片要載）——
            // `AsyncImage` 的載入中／失敗態在這一層看不到，那兩態也念「圖像」，比占位圖態誤念「沒有照片」好。
            .accessibilityAddTraits(content.cover == nil ? [] : .isImage)
            InteractionRow(
                kind: .album, refId: refId, timelineStore: timelineStore, familyStore: familyStore,
                onOpenComments: onOpenComments
            )
        }
    }

    /// Caption（`MIxHp`）：`$print-ink`／`$fs-body`／600，紙與墨不隨深色反轉。內縮 `$sp-group`
    /// 由 `PrintPhotoCard` 對 `imprintCaption` 統一套（LS-389），字起點＝紙左緣 20＝日記卡同軸。
    /// 字串走 `AlbumSignatureFormatter.captionText`（與相簿 tab 卡同源，不在此拼字元）；不設
    /// `lineLimit`——AX3 換行不截斷。LS-406 R2 M1：**所有字級固定單行公式**（`isMultiline: false`）——定案稿
    /// Notes `E2AtB`：AX3 相簿名與張數分兩行只給相簿頁卡（`AlbumSummaryCardView`）；時間軸板（含 AX3 的 `lKoZG`／
    /// `aGkJ1`，實例 `uvL4p`／`jGudh`）用「相簿名 · N 張相片」單行公式，放不下時折在標題內或「·」前。
    private var caption: some View {
        Text(AlbumSignatureFormatter.captionText(
            title: content.title, photoCount: content.photoCount, isMultiline: false
        ))
        .appNumericFont(.body, weight: .semibold)
        .foregroundStyle(Color.lsPrintInk)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
// LS-216 R2（merge-review R1 B1）：`timelineStore: .preview()` 是 DEBUG-only 工廠方法
// （`PreviewTimelineAPIClient.swift` 整支圍 `#if DEBUG`）——本檔原本的 `#Preview` 沒有圍欄
// （改前只用 `AlbumContent(...)`，不需要），本票加 `timelineStore` 參數後若不補圍欄，
// Release 組態會因為 `.preview()` 不存在而編譯失敗。同 `DiaryCardView.swift` 既有寫法。
#Preview {
    AlbumCardView(
        content: AlbumContent(title: "2026 夏天的海邊", photoCount: 8, cover: nil), timelineStore: .preview(),
        familyStore: .preview(), refId: UUID()
    )
        .padding()
}
#endif

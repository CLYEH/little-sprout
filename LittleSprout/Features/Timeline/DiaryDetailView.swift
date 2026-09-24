import SwiftUI

/// 日記詳情（LS-126 票文 Scope 2）——日期章錨定＋年齡、全文、瀑布流照片牆、互動列與留言 sheet
/// （LS-22 承接）。iPad 左右分欄：左欄 360pt 放照片牆、右欄放文字內容。
///
/// 只帶 `diaryID`：內文從 `timelineStore.entries` 依 id 查目前最新的一筆（同 `ChildrenRoute`
/// 的理由，見該檔文件註解），避免推入時捕捉到的舊資料在使用者停留期間過期。
///
/// LS-189：導覽列右上角「⋯」內容操作表入口（`design/littlesprout.pen` `WgbNc`，票文範圍 1）
/// ——`DiaryDeleteConfirmationSheet`（LS-190）曾經在這裡常駐插一顆「刪除日記」列，因為不判斷
/// 作者／家庭管理者身分被 merge-review 收回（見該檔文件註解）；這裡正式接回，入口與身分判斷
/// 都由 `DiaryDetailView+ContentActions.swift` 負責（見該檔）。
///
/// LS-241：原本 LS-126 預留的留言區占位文案（`commentsPlaceholder`，票文驗收要求全 repo
/// 0 hit，這裡不重複引用原字面）換成 LS-216 的
/// `InteractionRow`（同一顆元件、同一份 `timelineStore` 存的愛心／留言計數，跟時間軸卡片共用
/// 一套數字，不是各自一套）；`onOpenComments` 開 LS-218 的 `CommentsSheetView`。
/// `design/littlesprout.pen` 查無詳情頁專屬的互動列板（LS-177 只畫了三種卡片的規格板
/// `IgqGF`／`VZ0wV`／`Qzz3r`）——沿用占位原本的位置（compact layout 仍在文字內容 `VStack`
/// 裡），不新畫版面、只用 `InteractionRow` 自身的間距 token；iPad layout 見 `iPadLayout`
/// 文件註解（merge-review R2 M1，位置與 compact 不同）。
///
/// LS-245（池 `7f77856c`，LS-241 R1 merge-review m1）：留言 sheet 原本用獨立的
/// `showsCommentsSheet`（`Bool`）、「⋯」內容操作表原本用獨立的 `contentActionsContext`
/// （item），兩個各自獨立的 `.sheet` 呈現來源——留言 sheet 與「⋯」的非同步
/// `fetchContentAuthor` 完成窗口重疊時，第二個呈現會被系統丟棄，且 `contentActionsContext`
/// 的 `id` 恆為 `diaryID`，卡在非 nil 之後再次觸發（同一個 id）不會被視為新的呈現而重新彈出
/// ——「⋯」因此失效到退出重進才恢復。改成單一 `@State var activeSheet: DiaryDetailSheet?`
/// （見該 enum 文件註解）：兩個來源共用同一個 `.sheet(item:)`，任何時刻只有一個 case 是「目前
/// 要呈現的」，晚到的觸發直接覆蓋較早那個，不會卡住。內容操作表後續的確認鏈（檢舉／封鎖／
/// Owner 移除／刪除，`DiaryDetailView+ContentActions.swift` 的 `contentActionsSheetHost`）
/// 維持各自獨立的 `@State`：LS-190 R2 既有規約保證每一步都是「sheet 自己先 `dismiss()`，才
/// 呼叫成功回呼」，彼此依序接力、沒有非同步窗口重疊的空間，不在這次收斂範圍內。
///
/// LS-246（票文範圍 1，池 `8a00311d` i3）：上面「範圍決定」原本把影片播放排除在收斂範圍
/// 外——`playingVideo`（`.fullScreenCover(item:)`）留著當第三個獨立呈現來源，跟這裡併入
/// `activeSheet` 的留言 sheet／內容操作表並存。併回來的理由：`playVideo()` 一樣是先 tap、
/// 簽名 URL 回來才設狀態，若簽名回來時留言 sheet 或內容操作表恰好也在飛行中觸發，`.sheet`
/// 與 `.fullScreenCover` 會同時想呈現——SwiftUI 對「同一棵畫面樹上 `.sheet`／
/// `.fullScreenCover` 同時非 nil」沒有定義良好的行為（其中一個呈現會被忽略），跟原本
/// comments/contentActions 那組問題同一個成因。加了 `.video` case 之後，三個來源共用同一個
/// `Optional`，任何時刻只有一個「目前要呈現的」；`.sheet`／`.fullScreenCover` 兩種呈現風格
/// 不同、沒辦法掛在同一個 modifier 上，改用兩個各自只認自己 case 的 derived `Binding`
/// （`sheetBinding`／`videoBinding`，見 `DiaryDetailView` 屬性區文件註解）分別接
/// `.sheet(item:)`／`.fullScreenCover(item:)`，寫入端仍然只有這一個 `activeSheet`。
enum DiaryDetailSheet: Identifiable {
    case comments
    case contentActions(DiaryContentActionsContext)
    case video(PlayingVideo)

    var id: String {
        switch self {
        case .comments: "comments"
        case .contentActions(let context): "contentActions-\(context.id)"
        case .video(let video): "video-\(video.id)"
        }
    }
}

struct DiaryDetailView: View {
    let diaryID: UUID
    let timelineStore: TimelineStore
    let childrenStore: ChildrenStore
    /// LS-189：內容操作表需要「我是誰」「我是不是家庭管理者」「這篇日記是誰的」——
    /// `familyStore.ownerUserID`（其實是「我自己」的 user id，非家庭 owner 的 id，見該屬性
    /// 文件註解）／`familyStore.myFamily?.id`／`familyStore.members`（解析作者顯示名稱）。
    let familyStore: FamilyStore
    let safetyAPIClient: SafetyAPIClient
    /// LS-189：內容操作表「刪除」→ `DiaryDeleteConfirmationSheet`（LS-190）需要的既有 client。
    let diaryAPIClient: DiaryAPIClient
    /// LS-241：留言 sheet（`CommentsSheetView`，LS-218）用——同 `TimelineView.commentAPIClient`
    /// 既有理由。
    let commentAPIClient: CommentAPIClient

    @State private var photos: [MediaContent] = []
    @State private var loadState: TimelineOperationState = .idle
    @State private var photoWallWidth: CGFloat = UIScreen.main.bounds.width - 2 * AppSpacing.screenPad
    /// R2-m1（merge-review `b7ecfbf4`）：`playVideo` 現簽全尺寸 URL 前的 in-flight 去重旗標
    /// ——鍵是 `MediaContent.id`，同一支影片快速連點時第二次以後的 tap 直接忽略，不會對
    /// 同一支影片重複發 `POST /object/sign`（見 `playVideo` 文件註解）。
    @State private var preparingVideoIDs: Set<UUID> = []
    /// R2-m1：現簽全尺寸失敗時的行內錯誤——沿用 `photoWallSection` 既有的「附照載入失敗」
    /// 錯誤語彙（icon＋`Text(error.userFacingMessage)`），不是新設計；下次成功播放或再次
    /// 嘗試時清掉，不會一直卡在畫面上。
    @State private var videoPrepareError: AppError?
    // LS-189：內容操作表整條流程的狀態，見 `DiaryDetailView+ContentActions.swift`——不標
    // `private`：跨檔案 extension 存取不到（同 `SettingsView.regularSelection` 既有理由）。
    @State var isResolvingContentActions = false
    @State var reportFlowTarget: ContentActionTarget?
    @State var showsReportSent = false
    @State var blockConfirmContext: DiaryBlockConfirmContext?
    @State var removeConfirmTarget: ContentActionTarget?
    @State var showsDeleteConfirmation = false
    /// LS-245／LS-246：留言 sheet／「⋯」內容操作表（05）／影片播放三個呈現來源的單一狀態，
    /// 取代原本各自獨立的 `showsCommentsSheet`／`contentActionsContext`／`playingVideo`——見
    /// 檔頭文件註解、`DiaryDetailSheet`。不標 `private`：`DiaryDetailView+ContentActions.swift`
    /// （跨檔案 extension）需要寫入（同上面幾個內容操作表狀態的既有理由）。
    @State var activeSheet: DiaryDetailSheet?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) var dismiss

    // LS-189：不標 `private`——`DiaryDetailView+ContentActions.swift`（跨檔案 extension）需要
    // 讀取目前這篇日記的內文才能組出操作表的 headline（同 `regularSelection` 既有理由）。
    var entry: TimelineEntry? {
        timelineStore.entries.first { $0.kind == .diary && $0.refId == diaryID }
    }

    var diaryContent: DiaryContent? {
        guard case .diary(let content) = entry?.content else { return nil }
        return content
    }

    private var taggedChildren: [Child] {
        guard let entry else { return [] }
        return childrenStore.children.filter { entry.childIds.contains($0.id) }
    }

    var body: some View {
        Group {
            if let diaryContent {
                if horizontalSizeClass == .regular {
                    iPadLayout(diaryContent)
                } else {
                    compactLayout(diaryContent)
                }
            } else {
                missingOrLoadingState
            }
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        // QA 視覺對稿 FAIL（LS-126 comment `461bdc15`）：同 LS-125 DiaryEditorView 的缺陷
        // 模式——推入 tab 的畫面沒有隱藏 Tab Bar，稿面 `vzYXz` 完全沒有 Tab Bar 節點。iPad
        // 走 NavigationSplitView 的 detail pane，本來就沒有 Tab Bar 概念，這裡加上不影響。
        .toolbar(.hidden, for: .tabBar)
        // LS-189：內容操作表入口按鈕見 `header(_:)`（不是 `.toolbar`——nav bar bar button item
        // 的熱區不受內層 padding/frame 影響，`DiaryDetailView+ContentActions.swift` 文件註解
        // 有實測記錄；改成一般內容區塊的按鈕才能穩定撐到 ≥44×44pt）。整條流程的 `.sheet` 鏈掛在
        // `.overlay`（不可見的 `EmptyView`）上，不是內容本身——`.sheet` 掛在樹上哪個節點不影響
        // 呈現，這樣可以把整串 `.sheet` 鏈搬到另一個檔案而不必重新拆 `body` 本體（同業界常見的
        // 「用 overlay 集中多個 sheet modifier」寫法）。這裡剩下的是內容操作表 05 之後的確認鏈
        // （檢舉／封鎖／Owner 移除／刪除）——05 本身併進 `activeSheetHost`，見下一行與檔頭
        // LS-245 文件註解。
        .overlay(contentActionsSheetHost)
        // LS-245：留言 sheet／「⋯」內容操作表 05 的單一呈現來源（`activeSheet`）——同上一行
        // 理由，獨立一個 `.overlay`。
        .overlay(activeSheetHost)
        .task(id: diaryID) {
            loadState = .submitting
            do {
                photos = try await timelineStore.loadDiaryPhotos(diaryID: diaryID)
                loadState = .success
            } catch {
                loadState = .failure(AppError.map(error))
            }
        }
        // LS-246：改用 `videoBinding`（不是直接的 `@State`）——見該屬性文件註解，讓影片跟
        // 留言 sheet／內容操作表共用同一個 `activeSheet` 來源。
        .fullScreenCover(item: videoBinding) { video in
            VideoPlayerScreen(url: video.url).ignoresSafeArea()
        }
    }

    // MARK: - Compact (iPhone)

    private func compactLayout(_ content: DiaryContent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.block) {
                header(content)
                bodyText(content)
                photoWallSection
                interactionRow
            }
            // merge-review R1 M6：`.background` 必須掛在 `.padding` 之前（同 `ChildFilterBar`
            // 的既有寫法，見該檔）——`.background` 接在 `.padding` 之後量到的是「已經加上
            // padding 那一層」的 frame，會比照片牆真正可用的內容寬多 2×`screenPad`（48pt），
            // 讓 `MasonryLayout.place` 算出過寬的欄寬、照片牆貼齊螢幕邊緣，24pt 版心留白消失。
            .background(
                GeometryReader { proxy in
                    Color.clear.onAppear { photoWallWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in photoWallWidth = newValue }
                }
            )
            // Pen 對稿修正：稿面（`design/littlesprout.pen` frame `vzYXz`／`Body` 節點
            // `iUM2a`）Body padding 是 `[8,$screen-pad,0,$screen-pad]`——上緣只有
            // `$sp-label`（8pt，Nav Back 已經佔掉大半上緣空間）、下緣 0（交給內容自己的
            // 間距與安全區），不是四邊等值的 `screenPad`（24pt）。
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.label)
        }
    }

    // MARK: - Regular (iPad)：左欄 360pt 照片牆、右欄文字內容

    private func iPadLayout(_ content: DiaryContent) -> some View {
        ScrollView {
            // merge-review R2 M1：`interactionRow` 原本擠在右欄 `VStack` 裡——右欄寬＝pane −
            // 2×`screenPadLarge` − 360（照片欄）− `block`，側欄展開的 13" 直向只剩約 248pt，
            // 小於 `InteractionRow` 標準態橫向需求（≈291pt），「留言」字樣與計數被壓掉／折行
            // （reviewer 在 iPad mini 全寬 280pt 也重現）。移出兩欄 `HStack`、放最外層 `VStack`
            // 整寬（掃過的可用寬＝pane − 2×`screenPadLarge`，遠大於兩欄各自的寬度），同一台
            // 裝置換算下時間軸卡片可用寬本就夠、只有這個新版位不夠，不需要動 `InteractionRow`
            // 本身。
            VStack(alignment: .leading, spacing: AppSpacing.block) {
                HStack(alignment: .top, spacing: AppSpacing.block) {
                    MasonryPhotoWallView(
                        photos: photos, containerWidth: 360, timelineStore: timelineStore, onTapVideo: playVideo
                    )
                    .frame(width: 360, alignment: .leading)

                    VStack(alignment: .leading, spacing: AppSpacing.block) {
                        header(content)
                        bodyText(content)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                interactionRow
            }
            .padding(AppSpacing.screenPadLarge)
        }
    }

    // MARK: - 共用區塊

    private func header(_ content: DiaryContent) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.group) {
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                Text(BirthdayFormat.displayString(from: content.entryDate))
                    .appFont(.meta, weight: .semibold)
                    .foregroundStyle(Color.lsTextSecondary)
                if !taggedChildren.isEmpty {
                    Text(MultiChildCaptionFormatter.attributed(children: taggedChildren, asOf: content.entryDate))
                }
            }
            Spacer(minLength: AppSpacing.group)
            contentActionsButton
        }
    }

    /// merge-review R1 m4：簽名失敗（`signedURL == nil`）的影片格不該還能點開一個播不出
    /// 東西的全螢幕播放器——原寫法 `?? URL(string: "about:blank")!` 會讓這種格仍然可點。
    ///
    /// LS-130：`media.signedURL` 現在是縮圖優先的顯示用 URL（見 `TimelineContentAssembler.
    /// fetchDiaryPhotos`），不能直接拿來播放——縮圖是 JPEG（影片來源時取首幀），不是可播放
    /// 的影片檔。播放當下改現簽 `media.storagePath`（全尺寸原檔）；簽名失敗時同樣不播放。
    ///
    /// R2-m1（merge-review `b7ecfbf4`）：加 in-flight 去重（`preparingVideoIDs`）——同一支
    /// 影片快速連點原本會每次都起新 `Task`、各發一次簽名請求，先後回來的 URL 不同會讓
    /// `PlayingVideo.id`（＝URL）跟著變，`fullScreenCover(item:)` 拿到新 item 時輕則忽略、
    /// 重則整個重開播放器（影片從頭播）。簽名失敗（`throw` 或回傳 `nil`）時寫
    /// `videoPrepareError`，讓使用者看得到「點了但沒反應」的原因，不再是純靜默失敗。
    private func playVideo(_ media: MediaContent) {
        guard !preparingVideoIDs.contains(media.id) else { return }
        preparingVideoIDs.insert(media.id)
        videoPrepareError = nil
        Task {
            defer { preparingVideoIDs.remove(media.id) }
            do {
                guard let url = try await timelineStore.signFullSizeURL(storagePath: media.storagePath) else {
                    // 簽名沒 throw、但回傳 nil（同 signFullSizeURL 文件註解：檔案剛好被硬刪
                    // 這類情況）——不是可以「換個輸入再試」就會成功的狀態，歸 .rejected，
                    // `userFacingMessage` 自動給「無法完成這個操作」，不必自訂文案。
                    videoPrepareError = .rejected(message: "signFullSizeURL 回傳 nil：\(media.storagePath)", code: nil)
                    return
                }
                // LS-246：改寫共用的 `activeSheet`（不再是獨立的 `playingVideo`）——見
                // `DiaryDetailSheet`、`videoBinding` 文件註解。
                activeSheet = .video(PlayingVideo(url: url))
            } catch {
                videoPrepareError = AppError.map(error)
            }
        }
    }

    private func bodyText(_ content: DiaryContent) -> some View {
        Text(content.body)
            .appFont(.body)
            .foregroundStyle(Color.lsTextPrimary)
            .accessibilityIdentifier(QAAccessibilityID.diaryDetailBody)
    }

    @ViewBuilder
    private var photoWallSection: some View {
        if !photos.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                MasonryPhotoWallView(
                    photos: photos, containerWidth: photoWallWidth, timelineStore: timelineStore, onTapVideo: playVideo
                )
                // R2-m1：播放影片現簽全尺寸失敗時的行內提示——沿用下面「附照載入失敗」
                // 一模一樣的視覺語彙（icon＋note 字級＋`lsTextPrimary`），不是新設計；點了
                // 沒反應時使用者至少看得到原因，不再是純靜默失敗。
                if let videoPrepareError {
                    inlineErrorRow(videoPrepareError)
                }
            }
        } else if case .failure(let error) = loadState {
            // 日記內文本身載入成功、但附照那支查詢失敗時的行內提示——不吞掉錯誤
            // （fail loud），但也不因為附照失敗就整頁擋掉已經拿到的日記內文。
            inlineErrorRow(error)
        }
    }

    private func inlineErrorRow(_ error: AppError) -> some View {
        HStack(spacing: AppSpacing.tight) {
            Image(systemName: "exclamationmark.circle").appIconFrame(.small)
            Text(error.userFacingMessage).appFont(.note)
        }
        .foregroundStyle(Color.lsTextPrimary)
    }

    /// LS-241：互動列（LS-216）——愛心／留言計數同 `timelineStore`，跟時間軸卡片共用同一套
    /// 數字，不是各自一套（見檔頭文件註解）。
    private var interactionRow: some View {
        InteractionRow(
            kind: .diary, refId: diaryID, timelineStore: timelineStore, familyStore: familyStore,
            onOpenComments: { activeSheet = .comments }
        )
    }

    /// LS-245：留言 sheet／「⋯」內容操作表 05 的單一 `.sheet(item:)`——取代原本各自獨立的
    /// `commentsSheetHost`／`contentActionsSheetHost` 開頭那個 `.sheet(item: $contentActionsContext)`
    /// （見檔頭文件註解、`DiaryDetailSheet`）。`familyStore.myFamily?.id` 還沒填好時（同
    /// `isContentActionsReady` 的既有 guard 理由）留言 sheet 不呈現內容——`interactionRow` 的
    /// Comment Button 沒有另外做 `.disabled`（同三種時間軸卡片既有行為一致：`familyID` 缺席時
    /// 開出的 sheet 本來就是空的，不阻擋按鈕本身）。
    private var activeSheetHost: some View {
        EmptyView()
            // LS-246：改用 `sheetBinding`——`.video` case 的呈現交給 `videoBinding`／
            // `.fullScreenCover(item:)`（見 body），這裡不會真的收到 `.video`。
            .sheet(item: sheetBinding) { sheet in
                switch sheet {
                case .comments:
                    if let familyID = familyStore.myFamily?.id {
                        CommentsSheetView(
                            kind: .diary, refId: diaryID, familyID: familyID, timelineStore: timelineStore,
                            familyStore: familyStore, childrenStore: childrenStore,
                            commentAPIClient: commentAPIClient, safetyAPIClient: safetyAPIClient
                        )
                    }
                case .contentActions(let context):
                    ContentActionsSheet(headline: context.target.headline, actions: context.actions) { action in
                        handleContentAction(action, context: context)
                    }
                case .video:
                    // 不可達：`sheetBinding` 的 getter 只回傳 `.comments`／`.contentActions`
                    // （見該屬性文件註解），只是滿足 `DiaryDetailSheet` 窮舉 switch 的編譯要求。
                    EmptyView()
                }
            }
    }

    @ViewBuilder
    private var missingOrLoadingState: some View {
        // LS-189：`entry == nil` 原本無條件併進「還在載入」分支，會被 `loadState.isSubmitting
        // || entry == nil` 這個 `||` 永遠短路成 true——`entry` 從有變 nil（Owner 移除／自己
        // 刪除，見 `DiaryDetailView+ContentActions.swift` 的 `contentRemoved()` 呼叫
        // `timelineStore.removeDiaryEntryLocally`）之後，畫面會卡在無限轉圈，而不是顯示「找不到
        // 這篇日記」（UITest `testDiaryDetail_removeAsOwnerFlow_removesEntryLocally` 實測抓到）。
        // 改成：只有「這支 `.task(id: diaryID)` 從未跑過任何一輪」（`loadState == .idle`，涵蓋
        // 首次進場、`entry` 可能因為時序還沒同步的邊界情況）才視為「還在載入」；一旦跑過至少一輪
        // （`.submitting`／`.success`／`.failure` 皆是），`entry == nil` 就是「這篇日記真的不在
        // `timelineStore.entries` 裡了」，該顯示「找不到」而不是繼續轉圈。
        //
        // **隱性前提**（LS-189 R2，merge-review R1 m3，PLAUSIBLE）：`loadState` 是這支 view 自己
        // 的照片載入狀態機（`loadDiaryPhotos`），跟 `entry`（來自 `timelineStore.entries`）本身
        // 沒有因果關係——目前唯一入口是時間軸列表（進場時 `entry` 必非 nil），
        // `TimelineStore.refresh` 是 `entries = newEntries` 原子替換（見該檔文件註解）不會有
        // 中間空窗，所以現況下這個耦合不會被觸發。**但**日後若加 deep link／推播直接進日記
        // 詳情（`entry` 尚未載入就進場、`.task` 先把 `loadState` 推離 `.idle`），會秒顯示「找不
        // 到這篇日記」而不是轉圈——目前沒有可達路徑能寫出真的會失敗的回歸測試（reviewer 與
        // 實作者皆確認），記入待辦池 LS-96，等真的有 deep link 入口落地時一併補測試。
        if entry == nil && loadState != .idle {
            ContentUnavailableView(
                "找不到這篇日記",
                systemImage: "questionmark.circle",
                description: Text("這篇日記可能已經被移除。")
            )
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

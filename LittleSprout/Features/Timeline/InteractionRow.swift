import SwiftUI

/// 時間軸卡片互動列（LS-216 依 LS-177 稿 `IgqGF`／`VZ0wV`／`Qzz3r`；Handoff Notes `EclPC`
/// 節「卡片互動列」`a1wjoE`）——`DiaryCardView`／`AlbumCardView`／`PhotoCardView` 三種卡片
/// 共用同一份 SwiftUI View（稿面刻意只在 Pencil 檔案層級用 `Copy`／`Replace` 疊加避免動到
/// 共用元件本體，ios-dev 實作反過來：一份 View、三個呼叫端各自掛，見 Notes `h4wv16`）。
///
/// 結構：`Heart Group`（`Like Toggle`＋`Count Zone`，`$sp-tight` 間距）＋`Comment Button`，
/// 兩者之間 `$sp-block`（24pt）間距。AX3（`.accessibility3` 起）改直向堆疊——`Like Toggle`
/// 固定寬 220、`Count Zone` 56×80，兩者橫向相加已經逼近 iPhone 螢幕可用寬，稿面 `Qzz3r`
/// 的 `Interaction Row` 節點本身就帶 `layout:"vertical"`，同 `SectionTabBar.isAX3`／
/// `AlbumSummaryCardView.isOneLinePerPerson` 既有的兩態切換慣例（不是連續縮放曲線）。
///
/// **不巢在 `.accessibilityElement(children: .combine)` 裡**：三個呼叫端的卡片本體被外層
/// `TimelineView` 用 `NavigationLink`／整卡 tap 包住（`DiaryCardView`／`AlbumCardView`
/// 皆是），若 `InteractionRow` 的三顆 Button 落在同一個 `.combine` 範圍內，VoiceOver 只會
/// 唸出合併後的單一元素、三顆按鈕的獨立操作會消失——呼叫端把 `.combine` 只套在「純顯示」
/// 那一段（署名／內文／預覽照片），`InteractionRow` 留在 `.combine` 範圍外、作為手足節點
/// （見 `DiaryCardView`／`AlbumCardView`／`PhotoCardView` 的呼叫處註解）。同理，`Like
/// Toggle`／`Count Zone`／`Comment Button` 都是獨立 `Button`，落在外層 `NavigationLink`
/// 的可點範圍「內」但各自有自己的 `contentShape`／手勢——SwiftUI／UIKit 的觸控分派對「巢狀
/// 可互動元件」預設把命中的觸控交給階層最深的那個手勢辨識器，不是外層整片吃掉（同「相簿
/// 摘要卡＋Like 按鈕」這類 feed 卡片在原生 App 的常見寫法），已在模擬器實測驗證（見 LS-216
/// handoff「已驗證」）。
///
/// LS-245（池 `5824399c`）：非 AX3 態改用 `ViewThatFits` 在「留言」完整版與只留圖示＋計數的
/// `commentButtonCompact` 之間自動挑選——容器不夠寬時（LS-241 R1 在 iPad 詳情頁窄欄重現的
/// 截字問題）不再讓文字被硬截斷，見 `body`／`commentButtonCompact` 文件註解。
struct InteractionRow: View {
    let kind: FeedKind
    let refId: UUID
    let timelineStore: TimelineStore
    /// LS-345 R2：只為了轉手給 `LikersListSheet` 顯示按讚者真實頭像——見該型別文件註解。
    let familyStore: FamilyStore
    /// LS-218：`TimelineView.openComments(kind:refId:)` 接住這個回呼，開出
    /// `CommentsSheetView`（票文 scope 1）。
    var onOpenComments: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isToggling = false
    @State private var toggleError: AppError?
    @State private var likersSheetPresented = false

    private var isAX3: Bool { dynamicTypeSize >= .accessibility3 }
    private var targetKey: String { TimelineEntry.id(kind: kind, refId: refId) }
    private var reaction: ReactionState { timelineStore.reactionState(forKey: targetKey) }
    private var commentCount: Int { timelineStore.commentCount(forKey: targetKey) }

    private var heartIconSize: CGFloat { isAX3 ? 32 : 22 }
    private var likeToggleSize: CGSize { isAX3 ? CGSize(width: 220, height: 80) : CGSize(width: 118, height: 47) }
    private var countZoneSize: CGSize { isAX3 ? CGSize(width: 56, height: 80) : CGSize(width: 44, height: 44) }

    /// LS-366：未按讚 `Like Toggle`／`Count Zone`／`Comment Button` 的字色。稿面（`IgqGF`／
    /// `VZ0wV`）標 `$print-ink-secondary`，前提是互動列躺在 `cmp/Card Diary` 的 `$print-paper`
    /// 紙面上；但實作的互動列落在 theme-aware 底色上（`DiaryCardView` 的 `lsSurface`、
    /// `PhotoCardView`／`AlbumCardView` 相紙外的 `lsBackground`），`print-ink-secondary` 是刻意
    /// 不隨深色反轉的單值 token（tokens.md「紙上的墨」），深色底上只剩 1.44–1.69:1。改用它的
    /// theme-aware 對應 `text-secondary`：淺色同值 #553040（淺色零變化），深色 #D3AEB2
    /// 對 surface／bg 8.02／9.41:1。`internal` 讓單元測試量對比（`InteractionRowContrastTests`）。
    static let idleForeground = Color.lsTextSecondary

    var body: some View {
        Group {
            if isAX3 {
                VStack(alignment: .leading, spacing: AppSpacing.block) {
                    heartGroup
                    commentButton
                }
            } else {
                // LS-245（池 `5824399c`，LS-241 R1 首次暴露）：`heartGroup` 兩顆固定寬度熱區
                // （`likeToggleSize`／`countZoneSize`）在 `HStack` 裡不會被壓縮，容器不夠寬時
                // 擠壓全部落在 `commentButton` 身上——它的「留言」文字沒有 `.lineLimit`／
                // `.fixedSize`，先前只能眼睜睜被截字（LS-241 R1 在 iPad 詳情頁窄欄重現）。
                // `ViewThatFits` 用真實文字量測（不是猜一個像素常數）挑「放得下就用完整版、
                // 放不下換緊湊版」——比手動 `GeometryReader`＋門檻值更準：既有能放得下完整版的
                // 寬度（LS-241 reviewer 實測 iPad mini／13" 時間軸卡片欄寬）不會被誤判成需要
                // 降級，真的不夠寬（例如 iPad 分割視窗窄欄）才會退到 `commentButtonCompact`
                // （只留圖示＋計數，a11y label 仍是完整的「留言，N 則」，見該 var 文件註解）。
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppSpacing.block) {
                        heartGroup
                        commentButton
                    }
                    HStack(spacing: AppSpacing.block) {
                        heartGroup
                        commentButtonCompact
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $likersSheetPresented) {
            LikersListSheet(
                kind: kind, refId: refId, timelineStore: timelineStore, familyStore: familyStore,
                likeCount: reaction.count
            )
        }
        .alert(
            "按讚失敗",
            isPresented: Binding(get: { toggleError != nil }, set: { if !$0 { toggleError = nil } }),
            presenting: toggleError
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { error in
            Text(error.userFacingMessage)
        }
    }

    // MARK: - Heart Group

    private var heartGroup: some View {
        HStack(spacing: AppSpacing.tight) {
            likeToggle
            countZone
        }
    }

    private var likeToggle: some View {
        Button(action: toggleLike) {
            HStack(spacing: AppSpacing.tight) {
                heartIcon
                Text(reaction.reactedByMe ? "已按愛心" : "愛心")
                    .appFont(.note, weight: reaction.reactedByMe ? .bold : .regular)
            }
            .foregroundStyle(reaction.reactedByMe ? Color.lsAccent : Self.idleForeground)
            .padding(11)
            .frame(width: likeToggleSize.width, height: likeToggleSize.height, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isToggling)
        .accessibilityIdentifier(QAAccessibilityID.interactionRowElement(kind: kind.rawValue, element: "likeToggle"))
        .accessibilityLabel(reaction.reactedByMe ? "已按愛心" : "愛心")
        .accessibilityAddTraits(reaction.reactedByMe ? .isSelected : [])
    }

    @ViewBuilder
    private var heartIcon: some View {
        Image(systemName: reaction.reactedByMe ? "heart.fill" : "heart")
            .font(.system(size: heartIconSize))
            .frame(width: heartIconSize, height: heartIconSize)
    }

    /// 獨立熱區——與 `Like Toggle` 分離（票文 scope 1）：點擊開按讚名單，計數 0 時不開
    /// （票文 scope 3）。
    ///
    /// LS-216 R2（merge-review R1 minor m1，取代 R1 版的 `countZoneHitHeight` 計算屬性）：
    /// 標準態視覺尺寸 `countZoneSize`（44×44）貼齊硬約束下限，模擬器實測（`tap-target-
    /// check.sh`）量到 43.7pt（次像素捨入，同既有 `loadMoreTrigger` 文件註解點名的同類餘裕
    /// 不足案例）——第二層 `.frame(minWidth: 48, minHeight: 48)` 只在視覺尺寸小於 48 時才
    /// 撐大熱區（標準態 44→48），AX3（56×80）已經遠高於下限、`minWidth`／`minHeight` 對它是
    /// no-op，不受影響；只影響看不見的點擊區，不改變 `Count Zone` 本身沒有背景色塊、純文字
    /// 置中的視覺。
    ///
    /// LS-371：計數 0 時**不掛 `.disabled`**——`.disabled` 會讓 SwiftUI 把 `.plain` 按鈕整顆淡化
    /// 約 50%，計數「0」對底只剩 2.47–3.19:1（LS-366 QA `06a94284`），低於長輩硬約束 4.5:1；計數
    /// 是資訊、不是可用與否的提示，稿面 `IgqGF`／`VZ0wV`／`Qzz3r` 的 `Count Zone` 也只有一種
    /// 未按讚樣式、沒有淡化態（守在 `InteractionRowContrastTests`
    /// `.test_countZone_renderedCountMeetsElderContrast_inAllReactionStates`）。
    /// 改用 `.allowsHitTesting(reaction.count > 0)` 保留 `.disabled` 原本的點擊行為：0 讚時點在
    /// 計數上的 tap 穿透給外層卡片（開詳情），不會變成一塊點了沒反應的死區——新貼文多停在 0 讚，
    /// 短卡片的正中央常常就落在 Count Zone 上（`SectionTabBarPushRegressionTests` 點卡片中心
    /// 導覽即依賴這個行為）。其他不經 hit test 觸發 action 的途徑（例如 VoiceOver 啟用）仍由 `guard` 擋住。
    private var countZone: some View {
        Button {
            guard reaction.count > 0 else { return }
            likersSheetPresented = true
        } label: {
            Text("\(reaction.count)")
                .appFont(.note, weight: reaction.reactedByMe ? .bold : .semibold)
                .foregroundStyle(reaction.reactedByMe ? Color.lsAccent : Self.idleForeground)
                .frame(width: countZoneSize.width, height: countZoneSize.height)
                .frame(minWidth: 48, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(reaction.count > 0)
        .accessibilityIdentifier(QAAccessibilityID.interactionRowElement(kind: kind.rawValue, element: "countZone"))
        .accessibilityLabel("\(reaction.count) 人按了愛心")
        .accessibilityHint(reaction.count > 0 ? "顯示按讚名單" : "")
    }

    // MARK: - Comment Button

    private var commentButton: some View {
        Button(action: onOpenComments) {
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: "message")
                    .font(.system(size: heartIconSize))
                    .frame(width: heartIconSize, height: heartIconSize)
                Text("留言")
                    .appFont(.note)
                Text("\(commentCount)")
                    .appFont(.note, weight: .semibold)
            }
            .foregroundStyle(Self.idleForeground)
            .padding(11)
            .frame(minHeight: likeToggleSize.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(QAAccessibilityID.interactionRowElement(kind: kind.rawValue, element: "commentButton"))
        .accessibilityLabel("留言，\(commentCount) 則")
    }

    /// LS-245：`ViewThatFits` 量不到空間放得下「留言」字樣時的退路——只留圖示＋計數，padding／
    /// `minHeight`／`contentShape` 與完整版一致（票文範圍 1「熱區不變」），accessibility
    /// identifier／label 也不變（VoiceOver 使用者不受視覺降級影響，仍唸出完整的「留言，N 則」）。
    private var commentButtonCompact: some View {
        Button(action: onOpenComments) {
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: "message")
                    .font(.system(size: heartIconSize))
                    .frame(width: heartIconSize, height: heartIconSize)
                Text("\(commentCount)")
                    .appFont(.note, weight: .semibold)
            }
            .foregroundStyle(Self.idleForeground)
            .padding(11)
            .frame(minHeight: likeToggleSize.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(QAAccessibilityID.interactionRowElement(kind: kind.rawValue, element: "commentButton"))
        .accessibilityLabel("留言，\(commentCount) 則")
    }

    // MARK: - Actions

    private func toggleLike() {
        guard let familyID = timelineStore.familyID, !isToggling else { return }
        isToggling = true
        Task {
            defer { isToggling = false }
            do {
                try await timelineStore.toggleReaction(kind: kind, refId: refId, familyID: familyID)
            } catch {
                toggleError = AppError.map(error)
            }
        }
    }
}

#if DEBUG
#Preview {
    let store = TimelineStore.preview()
    let refId = UUID()
    store.seedReactionState(
        ReactionState(count: 3, reactedByMe: false), forKey: TimelineEntry.id(kind: .diary, refId: refId)
    )
    return VStack(alignment: .leading, spacing: AppSpacing.section) {
        InteractionRow(kind: .diary, refId: refId, timelineStore: store, familyStore: .preview())
    }
    .padding()
}
#endif

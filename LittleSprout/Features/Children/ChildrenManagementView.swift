import SwiftUI

/// LS-113 / 09（＋09 空狀態／09-iPad）寶貝管理。版式依 `design/littlesprout.pen` frame
/// `gpSsR`（有寶貝）／`lhvb5`（空狀態）／`JbTfv`（iPad split-view）：清單卡（沿用 07b 待核准
/// 卡片語彙，刻意不用沖印品母題——角托三段規則第③段，會被整理／刪除的清單不是收藏品）＋
/// 「已移除的寶貝」揭露列（僅 owner，可展開還原）＋「新增寶貝」主鈕。
///
/// R2 訂正（LS-67 `UhhwS` I1）：09 每列不再常駐「編輯／移除」兩個文字動作，整列本身就是一個
/// tap target 進 09b；「移除這個寶貝」只留在 09b 底部。
///
/// LS-312 導覽入口接線（orchestrator 裁決）：整列的目的地改成「寶貝詳情」
/// （`ChildGrowthDetailView`，稿 `jp6ka`）——09b（`EditChildView`）現在從詳情頁導覽列右上
/// 「編輯」進入，不再是列本身的目的地。`growthAPIClient` 只在建 `GrowthStore` 時用一次。
struct ChildrenManagementView: View {
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore
    let growthAPIClient: GrowthAPIClient

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showsRemovedList = false
    /// 不標 `private`：`ChildrenManagementView+Regular.swift` 的 `sidebarRow` 要寫入（同 `+Detail` 拆檔先例）。
    @State var selectedChildID: UUID?

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .task(id: familyStore.myFamily?.id) {
            guard let familyID = familyStore.myFamily?.id else { return }
            await childrenStore.refresh(familyID: familyID)
        }
    }

    // MARK: - Compact (iPhone)

    /// LS-344：`headerSection` 自畫「寶貝」標題，跟 `SectionContentView.content` 既有的
    /// `.navigationTitle(section.title)` 疊出兩個「寶貝」（實機 iPhone 12 Pro／iOS 26.5.2 與
    /// 模擬器 iOS 26.5 皆可重現）。改成跟 `TimelineView`／`AlbumsView` 同一種寫法：隱藏系統
    /// nav bar，`headerSection` 的 Text 補 `.accessibilityAddTraits(.isHeader)`（見下）取代
    /// 系統 large title 供應 entry-conditions.md ⑬ 的非手勢替代路徑。只套在 compact——regular
    /// （iPad）走的是內層 `NavigationSplitView`（`sidebarContent` 自己的 `.navigationTitle`），
    /// 疊在外層既有 `NavigationStack`／`NavigationSplitView` 之上已知行為複雜（見
    /// `regularLayout` 文件註解），本票只驗證了實機回報的 compact 這條路徑，iPad 是否同病記入
    /// handoff「未完成」，不在本票盲改。（LS-370 已拿掉內層 split，iPad 見 `regularLayout`。）
    private var compactLayout: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                contentCard
                    .padding(.top, AppSpacing.section)
                if childrenStore.isOwner && !childrenStore.removedChildren.isEmpty {
                    removedDisclosure
                        .padding(.top, AppSpacing.item)
                }
                Spacer(minLength: AppSpacing.item)
                if childrenStore.canManageChildren {
                    addChildButton
                        .padding(.bottom, AppSpacing.item)
                }
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
        }
        .appBackground()
        // LS-344：見上方 `compactLayout` 文件註解。
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: ChildrenRoute.self) { route in
            switch route {
            case .create:
                CreateChildView(childrenStore: childrenStore)
            case .detail(let childID):
                if let child = childrenStore.children.first(where: { $0.id == childID }) {
                    childDetail(for: child)
                }
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("寶貝")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                // LS-344：系統 nav bar 隱藏後，這顆自畫標題是唯一的 heading 訊號來源——同
                // `TimelineView`／`AlbumsView` 既有理由，補 heading trait 保留 VoiceOver 語意。
                .accessibilityAddTraits(.isHeader)
            Text(subtitleText)
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var subtitleText: String {
        let familyName = familyStore.myFamily?.name ?? ""
        let count = childrenStore.activeChildren.count
        if count == 0 {
            return "「\(familyName)」目前沒有寶貝的檔案。"
        }
        return "「\(familyName)」目前有 \(count) 個寶貝的檔案。"
    }

    @ViewBuilder
    private var contentCard: some View {
        if childrenStore.activeChildren.isEmpty {
            EmptyChildrenCard()
        } else {
            childrenCard
        }
    }

    private var childrenCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(childrenStore.activeChildren.enumerated()), id: \.element.id) { index, child in
                if index > 0 {
                    Rectangle().fill(Color.lsBorder).frame(height: 1)
                }
                childRow(child)
            }
        }
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                .strokeBorder(Color.lsBorder, lineWidth: 1)
        )
    }

    /// LS-312 R2（merge-review R1 m1，orchestrator 裁決）：寶貝詳情（`ChildGrowthDetailView`）
    /// 是唯讀畫面，所有家庭成員（含 viewer）都能開——不像過去目的地是 `EditChildView` 時只有
    /// `canManageChildren` 才能點。「編輯」入口本身仍限管理者，見 `childDetail(for:)` 的
    /// `editDestination` gate。
    private func childRow(_ child: Child) -> some View {
        NavigationLink(value: ChildrenRoute.detail(child.id)) {
            childRowContent(child)
        }
        .buttonStyle(.plain)
    }

    /// LS-313 順手項（LS-312 dead-code sweep `ac07c0ac` finding 1）：`showsChevron` 參數已是
    /// 死參數——R2 m1（`329f967`）收斂寶貝詳情為唯讀畫面後，`false`（不顯示 chevron）那條呼叫
    /// 路徑已被砍掉，全 repo 只剩上面這一個永遠傳 `true` 的呼叫點，改成無條件渲染 chevron。
    private func childRowContent(_ child: Child) -> some View {
        HStack(spacing: AppSpacing.group) {
            ChildAvatarView(name: child.name, avatarURL: childrenStore.avatarURL(for: child))
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                Text(child.name)
                    .appFont(.body, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                Pill(icon: "birthday.cake", text: BirthdayFormat.ageDescription(birthday: child.birthday))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .appIconFrame(.medium)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .padding(.vertical, AppSpacing.item)
        .padding(.horizontal, AppSpacing.insetCard)
        .contentShape(Rectangle())
    }

    private var removedDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showsRemovedList.toggle()
            } label: {
                HStack(spacing: AppSpacing.label) {
                    HStack(spacing: AppSpacing.label) {
                        Image(systemName: "archivebox")
                            .appIconFrame(.small)
                            .foregroundStyle(Color.lsTextSecondary)
                        Text("已移除的寶貝（\(childrenStore.removedChildren.count)）")
                            .appFont(.note, weight: .semibold)
                            .foregroundStyle(Color.lsTextSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: showsRemovedList ? "chevron.up" : "chevron.down")
                        .appIconFrame(.small)
                        .foregroundStyle(Color.lsTextSecondary)
                }
                // R1（模擬器實測抓到）：`$ctl-pad-tap` 撐不到 44pt 下限。
                .padding(.vertical, AppSpacing.controlPaddingMedium)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsRemovedList {
                VStack(spacing: AppSpacing.group) {
                    ForEach(childrenStore.removedChildren) { child in
                        removedRow(child)
                    }
                }
                .padding(.bottom, AppSpacing.group)
            }
        }
    }

    /// 灰化列本身就是還原動作（LS-67 `xf3jD`：這個入口只有 owner 看得到）——比照 10b 下拉
    /// 選單「已移除的寶貝」區段同一套視覺語彙，這裡整列可點，沒有另外的「還原」文字鈕。
    private func removedRow(_ child: Child) -> some View {
        Button {
            Task { await childrenStore.setChildDeleted(childID: child.id, deleted: false) }
        } label: {
            HStack(spacing: AppSpacing.label) {
                ChildAvatarView(
                    name: child.name, size: 28, isDimmed: true, avatarURL: childrenStore.avatarURL(for: child)
                )
                Text(child.name)
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextSecondary)
                Text("（已移除，點一下還原）")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
                Spacer(minLength: 0)
            }
            // R1（模擬器實測抓到）：同上，`$ctl-pad-tap` 撐不到 44pt。
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(childrenStore.deleteState.isSubmitting)
    }

    private var addChildButton: some View {
        NavigationLink(value: ChildrenRoute.create) {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "person.crop.circle.badge.plus").appIconFrame(.medium)
                Text("新增寶貝").appFont(.body)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.controlPaddingCTA)
            .padding(.horizontal, 20)
        }
        .foregroundStyle(Color.lsOnAccent)
        .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
    }

    // MARK: - Regular (iPad)

    /// 簡化版 iPad master-detail（見本檔文件註解的實作註記）：與 09-iPad 稿面的結構一致
    /// （左欄清單／新增，右欄詳情）。LS-312 導覽入口接線起，右欄改顯示寶貝詳情
    /// （`childDetail(for:)`，同 compact 版），「編輯」從詳情頁導覽列右上進入——與 compact
    /// 版同一套目的地，不再各自維護一份。未逐像素比照稿面把 09b「取消」文字鈕挪動位置——
    /// 這是本票在時間預算下的已知簡化，記於 handoff 風險欄。
    ///
    /// LS-370：原本這裡再包一層 `NavigationSplitView`，疊在 `RootView.SectionSplitView` 的
    /// detail 欄（它自己的 `NavigationStack`）裡——iPad Pro 13 上「寶貝」出現三次：外層系統
    /// large title、內層側欄 `.navigationTitle`、`headerSection` 自畫。稿面 `JbTfv`（09-iPad）
    /// 是單一 split：左 Sidebar（320pt，自畫 Title「寶貝」＋清單＋新增鈕）｜Divider｜右 Detail
    /// Pane，沒有系統標題。改成外層 split 的 detail 欄內用 `HStack` 畫這兩欄（同
    /// `SettingsView.regularBody` 拿掉內層 split 的先例，LS-188 merge-review R1 B1），不再有
    /// 第二層導覽容器；系統標題比照 `AlbumsView`（LS-355）／`TimelineView`（LS-369）：nav bar
    /// 保留（外層「顯示側邊欄」鈕的容身處，不得無條件隱藏——LS-344 R1 M1），`.inline`＋零尺寸
    /// `.principal` 關掉系統標題。已知行為：右欄「編輯」與左欄「新增寶貝」推到外層
    /// `NavigationStack`、蓋掉整個 detail 欄（同 `SettingsView.regularBody` 已記載的限制）。
    /// 回歸測試：`ChildrenManagementViewIPadTests`。
    private var regularLayout: some View {
        HStack(spacing: 0) {
            sidebarContent
                .frame(width: 320)
            Divider()
            Group {
                if let selectedChildID, let child = childForID(selectedChildID) {
                    childDetail(for: child)
                } else {
                    ContentUnavailableView(
                        "選擇一個寶貝",
                        // LS-160：與 LS-150 已核可的寶貝 tab icon 語彙一致（AppSection.children.systemImage）。
                        systemImage: "stroller.fill",
                        description: Text("在左側選擇要編輯的寶貝檔案。")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 0, height: 0).accessibilityHidden(true) }
        }
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            headerSection
                .padding(.horizontal, AppSpacing.screenPadLarge)
                .padding(.top, AppSpacing.screenPadLarge)
            // LS-370：不用 `List(selection:)`，理由見 `ChildrenManagementView+Regular.swift`。
            ScrollView {
                VStack(spacing: AppSpacing.tight) {
                    ForEach(childrenStore.activeChildren) { child in
                        sidebarRow(child)
                    }
                }
                .padding(.leading, AppSpacing.screenPadLarge)
                .padding(.trailing, AppSpacing.block)
            }
            if childrenStore.canManageChildren {
                NavigationLink {
                    CreateChildView(childrenStore: childrenStore)
                } label: {
                    HStack(spacing: AppSpacing.label) {
                        Image(systemName: "person.crop.circle.badge.plus").appIconFrame(.medium)
                        Text("新增寶貝").appFont(.body)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.controlPaddingCTA)
                }
                .foregroundStyle(Color.lsOnAccent)
                .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                .padding(.horizontal, AppSpacing.screenPadLarge)
                .padding(.bottom, AppSpacing.item)
            }
        }
    }
}

/// 09 空狀態的沖印品母題（LS-67 R2 `UhhwS` F8/I7：空清單卡改換成空白沖印品，不再用
/// image-off／相機圓形 icon）——白邊＋角托＋壓印行單一空白，同 `CreateFamilyView
/// .FamilyPreviewCard` 的 `content:" "` 慣例，撐住行高，不因為沒有內容而讓卡片高度塌縮。
private struct EmptyChildrenCard: View {
    private static let mountPoolOpacity = PrintPhotoCard.MountPoolOpacity(
        topLeading: 0.418, topTrailing: 0.271, bottomLeading: 0.32, bottomTrailing: 0.215
    )

    var body: some View {
        VStack(spacing: 7) {
            Color.lsSurface2.frame(height: 175)
            Text(" ")
                .appFont(.lead, weight: .semibold)
                .foregroundStyle(Color.lsPrintInk)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, AppSpacing.printEdge)
        .padding(.horizontal, AppSpacing.printEdge)
        .padding(.bottom, AppSpacing.printEdgeBottom)
        .background(mountPoolGlow.clipped())
        .background(Color.lsPrintPaper)
        .overlay(PhotoCornerOverlay(size: 26))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("目前沒有寶貝的檔案")
    }

    private var mountPoolGlow: some View {
        GeometryReader { proxy in
            let diameter: CGFloat = 156
            ZStack {
                glow(diameter: diameter, opacity: Self.mountPoolOpacity.topLeading).position(x: 0, y: 0)
                glow(diameter: diameter, opacity: Self.mountPoolOpacity.topTrailing)
                    .position(x: proxy.size.width, y: 0)
                glow(diameter: diameter, opacity: Self.mountPoolOpacity.bottomLeading)
                    .position(x: 0, y: proxy.size.height)
                glow(diameter: diameter, opacity: Self.mountPoolOpacity.bottomTrailing)
                    .position(x: proxy.size.width, y: proxy.size.height)
            }
        }
    }

    private func glow(diameter: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.lsMountPool.opacity(opacity), Color.lsMountPoolFade],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview("有寶貝") {
    NavigationStack {
        ChildrenManagementView(
            familyStore: .preview(), childrenStore: .preview(), growthAPIClient: PreviewGrowthAPIClient()
        )
    }
}
#endif

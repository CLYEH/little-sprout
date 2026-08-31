import SwiftUI

/// LS-113 / 09（＋09 空狀態／09-iPad）寶貝管理。版式依 `design/littlesprout.pen` frame
/// `gpSsR`（有寶貝）／`lhvb5`（空狀態）／`JbTfv`（iPad split-view）：清單卡（沿用 07b 待核准
/// 卡片語彙，刻意不用沖印品母題——角托三段規則第③段，會被整理／刪除的清單不是收藏品）＋
/// 「已移除的寶貝」揭露列（僅 owner，可展開還原）＋「新增寶貝」主鈕。
///
/// R2 訂正（LS-67 `UhhwS` I1）：09 每列不再常駐「編輯／移除」兩個文字動作，整列本身就是一個
/// tap target 進 09b；「移除這個寶貝」只留在 09b 底部。
struct ChildrenManagementView: View {
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showsRemovedList = false
    @State private var selectedChildID: UUID?

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
        .navigationDestination(for: ChildrenRoute.self) { route in
            switch route {
            case .create:
                CreateChildView(childrenStore: childrenStore)
            case .edit(let childID):
                if let child = childrenStore.children.first(where: { $0.id == childID }) {
                    EditChildView(childrenStore: childrenStore, child: child)
                }
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("寶貝")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
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

    @ViewBuilder
    private func childRow(_ child: Child) -> some View {
        if childrenStore.canManageChildren {
            NavigationLink(value: ChildrenRoute.edit(child.id)) {
                childRowContent(child, showsChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            childRowContent(child, showsChevron: false)
        }
    }

    private func childRowContent(_ child: Child, showsChevron: Bool) -> some View {
        HStack(spacing: AppSpacing.group) {
            ChildAvatarView(name: child.name)
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                Text(child.name)
                    .appFont(.body, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                Pill(icon: "birthday.cake", text: BirthdayFormat.ageDescription(birthday: child.birthday))
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .appIconFrame(.medium)
                    .foregroundStyle(Color.lsTextSecondary)
            }
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
                ChildAvatarView(name: child.name, size: 28, isDimmed: true)
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
    /// （左欄清單／新增，右欄編輯表單），但右欄直接重用 `EditChildView`（含它自己的
    /// 「取消」文字鈕），未逐像素比照稿面把「取消」拿掉、把「移除這個寶貝」搬到「儲存變更」
    /// 之前——這是本票在時間預算下的已知簡化，記於 handoff 風險欄。
    private var regularLayout: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            NavigationStack {
                if let selectedChildID, childrenStore.children.contains(where: { $0.id == selectedChildID }) {
                    EditChildView(childrenStore: childrenStore, child: childForID(selectedChildID)!)
                } else {
                    ContentUnavailableView(
                        "選擇一個寶貝",
                        systemImage: "figure.and.child.holdinghands",
                        description: Text("在左側選擇要編輯的寶貝檔案。")
                    )
                }
            }
        }
    }

    private func childForID(_ id: UUID) -> Child? {
        childrenStore.children.first { $0.id == id }
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            headerSection
                .padding(.horizontal, AppSpacing.screenPadLarge)
                .padding(.top, AppSpacing.screenPadLarge)
            List(childrenStore.activeChildren, selection: $selectedChildID) { child in
                HStack(spacing: AppSpacing.group) {
                    ChildAvatarView(name: child.name)
                    VStack(alignment: .leading, spacing: AppSpacing.tight) {
                        Text(child.name).appFont(.body, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                        Text(BirthdayFormat.ageDescription(birthday: child.birthday))
                            .appFont(.note)
                            .foregroundStyle(Color.lsTextSecondary)
                    }
                }
                .tag(child.id)
            }
            .listStyle(.plain)
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
        .navigationTitle("寶貝")
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

#Preview("有寶貝") {
    NavigationStack {
        ChildrenManagementView(familyStore: .preview(), childrenStore: .preview())
    }
}

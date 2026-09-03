import SwiftUI

/// LS-113 / 10（＋10b／AX3 強制下拉）時間軸頂部寶貝切換器。版式依
/// `design/littlesprout.pen` `ebuFg`（分段，≤3 或寬度足夠）／`xgx94`（下拉，>3 或寬度不夠、
/// 或 AX3）：分段/下拉的取捨用**寬度**判斷，不是數量判斷，見 `ChildFilterLayout` 文件註解。
///
/// 時間軸本身（照片／日記混排）是 Phase 1-5 的範圍（`TimelineView` 目前仍是 placeholder，
/// 見該檔），本元件只負責「選哪個寶貝」這件事本身；FAB／底部 Tab Bar／時間軸卡片是另一批
/// 尚未落地的既有／未來票，不在本票範圍內（LS-113 票文 Scope 只列「時間軸頂部分段，>3 改
/// 下拉」）。
struct ChildFilterBar: View {
    let childrenStore: ChildrenStore
    @Binding var selectedChildID: UUID?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var availableWidth: CGFloat = UIScreen.main.bounds.width - 2 * AppSpacing.screenPad
    @State private var showsDropdownMenu = false

    private var activeChildren: [Child] { childrenStore.activeChildren }
    private var removedChildren: [Child] { childrenStore.removedChildren }

    private var useDropdown: Bool {
        ChildFilterLayout.shouldUseDropdown(
            childNames: activeChildren.map(\.name),
            availableWidth: availableWidth,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    var body: some View {
        Group {
            if useDropdown {
                dropdownButton
            } else {
                segmentedTrack
            }
        }
        // R1（模擬器實測抓到）：容器（例如 `TimelineView` 的 `VStack`）不會自動把「其餘
        // 子視圖用剩的寬度」硬塞給這個非彈性子視圖——沒有這個 `frame`，分段控制會整組
        // 縮成內容自然寬（只有 1 個寶貝時實測縮到 43×28pt，遠低於 44pt 點擊下限），
        // GeometryReader 量到的 `availableWidth` 也會跟著錯，連帶讓分段／下拉的判斷失準。
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in availableWidth = newValue }
            }
        )
    }

    // MARK: - 分段（`ebuFg`）

    private var segmentedTrack: some View {
        HStack(spacing: 0) {
            segment(title: "全部", isSelected: selectedChildID == nil) { selectedChildID = nil }
            ForEach(activeChildren) { child in
                segment(child: child, isSelected: selectedChildID == child.id) { selectedChildID = child.id }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(3)
        .background(Color.lsSurface2, in: Capsule())
    }

    /// R1（模擬器實測抓到的真實 bug，不是理論風險）：`.frame(maxWidth: .infinity)` 加在
    /// **label 內部**（`Text`／`HStack` 上）時，只在寶貝人數少、`HStack` 內含固定尺寸子視圖
    /// （`ChildAvatarView` 的頭像圓）的那個 segment 上失效——視覺背景膠囊縮回內容自然寬
    /// （43pt，遠低於 44pt 下限），即使加了 `contentShape(Rectangle())` 讓「命中測試」
    /// 範圍變寬，視覺膠囊仍然是小的（兩者是分開的兩件事：`contentShape` 只擴大點擊判定，
    /// 不會讓 `.background(in:)` 畫的形狀跟著變大）。真正的修法是把 `.frame(maxWidth:
    /// .infinity)` 改綁在 **Button 本身**（label 收工、`.buttonStyle` 之前），讓整顆
    /// Button（含它畫出來的背景）依此撐開，而不是寄望 label 內部的 frame 修飾詞往上
    /// 傳遞彈性——同樣的寫法兩個 segment 都套用，行為就一致。
    private func segment(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .appFont(.body, weight: .bold)
                .foregroundStyle(isSelected ? Color.lsTextPrimary : Color.lsTextSecondary)
                .padding(.vertical, AppSpacing.controlPaddingMedium)
                .padding(.horizontal, AppSpacing.item)
                .frame(maxWidth: .infinity)
                .background(isSelected ? Color.lsSurface : Color.clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func segment(child: Child, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.tight) {
                ChildAvatarView(name: child.name, size: 28)
                Text(child.name)
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(isSelected ? Color.lsTextPrimary : Color.lsTextSecondary)
            }
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .padding(.horizontal, AppSpacing.item)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.lsSurface : Color.clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 下拉（`xgx94`）

    private var dropdownButton: some View {
        Button {
            showsDropdownMenu = true
        } label: {
            HStack(spacing: AppSpacing.tight) {
                Text(selectedLabel)
                    .appFont(.body, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                Image(systemName: "chevron.down")
                    .appIconFrame(.small)
                    .foregroundStyle(Color.lsTextPrimary)
            }
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .padding(.horizontal, AppSpacing.item)
            .background(Color.lsSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.lsControlLine, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsDropdownMenu) {
            dropdownMenuContent
                .presentationCompactAdaptation(.popover)
        }
    }

    private var selectedLabel: String {
        guard let selectedChildID else { return "全部" }
        return activeChildren.first { $0.id == selectedChildID }?.name ?? "全部"
    }

    private var dropdownMenuContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuRow(title: "全部", icon: "person.2.fill", isSelected: selectedChildID == nil) {
                selectedChildID = nil
                showsDropdownMenu = false
            }
            ForEach(activeChildren) { child in
                menuRow(child: child, isSelected: selectedChildID == child.id) {
                    selectedChildID = child.id
                    showsDropdownMenu = false
                }
            }
            if childrenStore.isOwner && !removedChildren.isEmpty {
                Rectangle().fill(Color.lsBorder).frame(height: 1)
                    .padding(.vertical, AppSpacing.tight)
                Text("已移除的寶貝")
                    .appFont(.note, weight: .semibold)
                    .foregroundStyle(Color.lsTextSecondary)
                    .padding(.horizontal, AppSpacing.label)
                    .padding(.top, AppSpacing.tight)
                ForEach(removedChildren) { child in
                    removedMenuRow(child)
                }
            }
        }
        .padding(AppSpacing.tight)
        .frame(width: 240)
    }

    private func menuRow(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: icon).appIconFrame(.medium).foregroundStyle(Color.lsTextPrimary)
                Text(title).appFont(.body, weight: isSelected ? .bold : .semibold).foregroundStyle(Color.lsTextPrimary)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark").appIconFrame(.medium).foregroundStyle(Color.lsTextPrimary)
                }
            }
            // R1（模擬器實測抓到）：`$ctl-pad-tap` 撐不到 44pt 下限，這裡改用較大的
            // 內距（同本檔其餘 44pt 修正的理由）。
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .padding(.horizontal, AppSpacing.label)
            .background(menuRowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    private func menuRow(child: Child, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.label) {
                ChildAvatarView(name: child.name, size: 28)
                Text(child.name)
                    .appFont(.body, weight: isSelected ? .bold : .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark").appIconFrame(.medium).foregroundStyle(Color.lsTextPrimary)
                }
            }
            // R1（模擬器實測抓到）：`$ctl-pad-tap` 撐不到 44pt 下限，這裡改用較大的
            // 內距（同本檔其餘 44pt 修正的理由）。
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .padding(.horizontal, AppSpacing.label)
            .background(menuRowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    private func menuRowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
            .fill(isSelected ? Color.lsAccentSoft : Color.clear)
    }

    /// 灰化列本身就是還原動作，同 `ChildrenManagementView.removedRow` 的語彙（僅 owner 看得到，
    /// LS-67 `xf3jD`）。
    private func removedMenuRow(_ child: Child) -> some View {
        Button {
            Task { await childrenStore.setChildDeleted(childID: child.id, deleted: false) }
        } label: {
            HStack(spacing: AppSpacing.label) {
                ChildAvatarView(name: child.name, size: 28, isDimmed: true)
                Text(child.name).appFont(.body, weight: .semibold).foregroundStyle(Color.lsTextSecondary)
                Text("（已移除，點一下還原）").appFont(.note).foregroundStyle(Color.lsTextSecondary)
                Spacer(minLength: 0)
            }
            // R1（模擬器實測抓到）：`$ctl-pad-tap` 撐不到 44pt 下限，這裡改用較大的
            // 內距（同本檔其餘 44pt 修正的理由）。
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .padding(.horizontal, AppSpacing.label)
        }
        .buttonStyle(.plain)
        .disabled(childrenStore.deleteState.isSubmitting)
    }
}

#if DEBUG
private struct ChildFilterBarPreview: View {
    @State private var selectedChildID: UUID?

    var body: some View {
        ChildFilterBar(childrenStore: .preview(), selectedChildID: $selectedChildID)
            .padding()
    }
}

#Preview {
    ChildFilterBarPreview()
}
#endif

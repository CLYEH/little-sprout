import SwiftUI

/// 記錄日期／寶貝歸屬兩個推入式欄位（`design/littlesprout.pen` `LS-21 / 12` Date Field／
/// Child Field）：整個欄位方塊是唯一 tap target，點下去分別開系統日期選擇器 `.sheet` 與
/// `AttributionSheet`——實際的雙向 binding 只活在各自 `.sheet` 內容建構那一刻（`DiaryEditorView.
/// body` 已經在那裡做過 `@Bindable var store = store`），這裡只需要唯讀 `store` 顯示目前值。
extension DiaryEditorView {
    var dateFieldSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("記錄日期").appFont(.body, weight: .bold).foregroundStyle(Color.lsTextPrimary)
            dateFieldBox
            fieldHelp(text: "預設是今天，也可以往前選，補寫之前忘記寫的日子。")
        }
    }

    private var dateFieldBox: some View {
        Button {
            showsDatePicker = true
        } label: {
            HStack {
                HStack(spacing: AppSpacing.label) {
                    Image(systemName: "calendar").appIconFrame(.medium).foregroundStyle(Color.lsTextSecondary)
                    Text(DiaryDateFormat.displayString(for: store.entryDate))
                        .appFont(.body, weight: .semibold)
                        .foregroundStyle(Color.lsTextPrimary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").appIconFrame(.medium).foregroundStyle(Color.lsTextSecondary)
            }
            .padding(.horizontal, AppSpacing.insetCard)
            .frame(minHeight: 60)
            .background(fieldBackground, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.publishState.isInFlight)
    }

    private func fieldHelp(text: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "info").appIconFrame(.small).foregroundStyle(Color.lsTextSecondary)
            Text(text).appFont(.note).foregroundStyle(Color.lsTextSecondary)
        }
    }

    // MARK: - 寶貝歸屬

    var childFieldSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("這篇日記是哪個寶貝的？").appFont(.body, weight: .bold).foregroundStyle(Color.lsTextPrimary)
            childFieldBox
        }
    }

    private var childFieldBox: some View {
        Button {
            showsAttributionSheet = true
        } label: {
            HStack {
                HStack(spacing: AppSpacing.label) {
                    selectedChildrenAvatarStack
                    Text(selectedChildrenSummaryText)
                        .appFont(.body, weight: .semibold)
                        .foregroundStyle(store.isUnspecifiedChild ? Color.lsTextSecondary : Color.lsTextPrimary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").appIconFrame(.medium).foregroundStyle(Color.lsTextSecondary)
            }
            .padding(.horizontal, AppSpacing.insetCard)
            .padding(.vertical, AppSpacing.group)
            .frame(minHeight: 56)
            .background(fieldBackground, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.publishState.isInFlight)
    }

    private var selectedChildren: [Child] {
        childrenStore.activeChildren.filter { store.selectedChildIDs.contains($0.id) }
    }

    private var selectedChildrenSummaryText: String {
        // 頓號「、」列出多個獨立的人——刻意跟年齡標籤用的「·」不同字（`design/littlesprout.pen`
        // Handoff Notes `B5Tahj`）。
        store.isUnspecifiedChild ? "不指定" : selectedChildren.map(\.name).joined(separator: "、")
    }

    /// R3 既有修正：AX3 下固定尺寸頭像＋姓名縮寫文字會被壓縮撐爆容器，覆寫到 64×64（重疊
    /// 24pt）；一般字級維持 32×32（重疊 20pt）——兩檔離散值，不是連續縮放（同 `ChildAvatarView`
    /// 文件註解：縮寫本身是裝飾性識別符號，不吃 Dynamic Type，這裡改的是「用哪個固定尺寸」）。
    private var avatarSize: CGFloat { dynamicTypeSize.isAccessibilitySize ? 64 : 32 }
    private var avatarOverlap: CGFloat { dynamicTypeSize.isAccessibilitySize ? 24 : 20 }

    @ViewBuilder
    private var selectedChildrenAvatarStack: some View {
        if selectedChildren.isEmpty {
            Image(systemName: "person.2")
                .appIconFrame(.medium)
                .foregroundStyle(Color.lsTextSecondary)
        } else {
            ZStack(alignment: .leading) {
                ForEach(Array(selectedChildren.prefix(2).enumerated()), id: \.element.id) { index, child in
                    ChildAvatarView(name: child.name, size: avatarSize)
                        .overlay(Circle().strokeBorder(Color.lsSurface, lineWidth: 2))
                        .offset(x: CGFloat(index) * avatarOverlap)
                }
            }
            .frame(
                width: selectedChildren.count > 1 ? avatarSize + avatarOverlap : avatarSize,
                height: avatarSize
            )
        }
    }
}

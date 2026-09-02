import SwiftUI

/// 「這篇日記是哪個寶貝的？」多選底部選單（`design/littlesprout.pen` `zgVn0`／`mkR0z`，
/// LS-47/10c 共用元件；LS-125 R5 改多選）。目前唯一呼叫端是 `DiaryEditorView`——相簿發佈流程
/// 若之後也要用同一份規格，直接重用本檔即可，不需要另外出一份設計稿（元件本身就是共用的）。
///
/// 「不指定」與任何寶貝互斥：`selectedChildIDs` 空集合＝不指定；非空＝已指定那幾個寶貝。這裡
/// 不另外維護一顆「是否不指定」的旗標，避免跟集合狀態失去同步（`DiaryComposerStore` 同一個
/// 判斷式，見該檔 `isUnspecifiedChild`）。
struct AttributionSheet: View {
    let childrenStore: ChildrenStore
    @Binding var selectedChildIDs: Set<UUID>

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headSection
                .padding(.top, AppSpacing.section)
            ScrollView {
                optionsSection
                    .padding(.top, AppSpacing.section)
            }
            confirmButton
                .padding(.top, AppSpacing.block)
                .padding(.bottom, AppSpacing.item)
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .background(Color.lsSurface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var headSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("這篇日記是哪個寶貝的？")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("之後隨時可以再改，也可以不指定。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            unspecifiedRow
            Rectangle().fill(Color.lsBorder).frame(height: 1)
                .padding(.vertical, AppSpacing.label)
            ForEach(childrenStore.activeChildren) { child in
                childRow(child)
            }
        }
    }

    private var unspecifiedRow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            optionRow(isSelected: selectedChildIDs.isEmpty) {
                Circle()
                    .fill(Color.lsSurface2)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "circle.slash")
                            .appIconFrame(.medium)
                            .foregroundStyle(Color.lsTextSecondary)
                    )
            } label: {
                Text("不指定").appFont(.body, weight: .bold).foregroundStyle(Color.lsTextPrimary)
            } action: {
                selectedChildIDs.removeAll()
            }
            Text("選了這個就不會標記任何寶貝")
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
                .padding(.leading, 56 + AppSpacing.label)
        }
    }

    private func childRow(_ child: Child) -> some View {
        optionRow(isSelected: selectedChildIDs.contains(child.id)) {
            ChildAvatarView(name: child.name, size: 48)
        } label: {
            Text(child.name).appFont(.body, weight: .bold).foregroundStyle(Color.lsTextPrimary)
        } action: {
            toggle(child.id)
        }
    }

    private func optionRow(
        isSelected: Bool,
        @ViewBuilder leading: () -> some View,
        @ViewBuilder label: () -> some View,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.label) {
                leading()
                label()
                Spacer(minLength: 0)
                checkbox(isSelected: isSelected)
            }
            .padding(.vertical, AppSpacing.item)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func checkbox(isSelected: Bool) -> some View {
        Circle()
            .fill(isSelected ? Color.lsTextPrimary : Color.clear)
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(Color.lsControlLine, lineWidth: isSelected ? 0 : 1.5))
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.lsSurface)
                }
            }
    }

    private func toggle(_ childID: UUID) {
        if selectedChildIDs.remove(childID) == nil {
            selectedChildIDs.insert(childID)
        }
    }

    private var confirmButton: some View {
        PrimaryButton(icon: "checkmark", title: "完成", action: { dismiss() })
    }
}

#Preview {
    AttributionSheetPreviewHost()
}

private struct AttributionSheetPreviewHost: View {
    @State private var selected: Set<UUID> = []

    var body: some View {
        Color.lsBackground
            .sheet(isPresented: .constant(true)) {
                AttributionSheet(childrenStore: .preview(), selectedChildIDs: $selected)
            }
    }
}

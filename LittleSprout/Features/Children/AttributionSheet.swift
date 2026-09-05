import SwiftUI

/// 「這篇日記是哪個寶貝的？」多選底部選單（`design/littlesprout.pen` `zgVn0`／`mkR0z`，
/// LS-47/10c 共用元件；LS-125 R5 改多選）。目前唯一呼叫端是 `DiaryEditorView`——相簿發佈流程
/// 若之後也要用同一份規格，直接重用本檔即可，不需要另外出一份設計稿（元件本身就是共用的）。
///
/// LS-165：`CreateAlbumView`（新增相簿 sheet）是第二個呼叫端，比照這則文件註解的既有指示直接
/// 重用本檔，但「這篇日記」的字面文案對相簿情境不成立——`title`／`subtitle` 因此開放覆寫
/// （預設值＝原本寫死的日記文案，`DiaryEditorView` 呼叫端不需要跟著改），版面／互動邏輯完全
/// 不變，只是文字改成可帶入的參數。
///
/// 「不指定」與任何寶貝互斥：`selectedChildIDs` 空集合＝不指定；非空＝已指定那幾個寶貝。這裡
/// 不另外維護一顆「是否不指定」的旗標，避免跟集合狀態失去同步（`DiaryComposerStore` 同一個
/// 判斷式，見該檔 `isUnspecifiedChild`）。
struct AttributionSheet: View {
    let childrenStore: ChildrenStore
    @Binding var selectedChildIDs: Set<UUID>
    var title = "這篇日記是哪個寶貝的？"
    var subtitle = "之後隨時可以再改，也可以不指定。"

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headSection
                .padding(.top, AppSpacing.section)
            ScrollView {
                // R5 對稿（`design/littlesprout.pen` `zgVn0`／`na6Qp`）：Head 到 Options 量到
                // 的間距是 `$sp-block`（24），不是 `$sp-section`（44）——後者是 `headSection`
                // 自己頂端到系統拖曳把手的間距，兩段不是同一個量。
                optionsSection
                    .padding(.top, AppSpacing.block)
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
            Text(title)
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text(subtitle)
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            unspecifiedRow
            // R5 對稿：分隔線上下量到的是 `$sp-block`（24），不是 `$sp-label`（8）。
            Rectangle().fill(Color.lsBorder).frame(height: 1)
                .padding(.vertical, AppSpacing.block)
            // R5 對稿：同一組（寶貝清單）裡相鄰兩列之間量到 `$sp-tight`（6）的呼吸間距，先前
            // 用扁平 `ForEach`＋外層 `spacing: 0`，列與列之間完全貼齊、沒有這段間距。
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                ForEach(childrenStore.activeChildren) { child in
                    childRow(child)
                }
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

#if DEBUG
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
#endif

import SwiftUI

/// 03c 記錄列操作表（LS-313，`design/littlesprout.pen` Notes `h5BNyi`→`z1QNs`，「非手勢替代
/// 路徑」——03 記錄列表副標「左滑或點一列都可以編輯、刪除」，這支畫面是「點一列」那個路徑）。
///
/// 不重用 `ContentActionsSheet`／`ContentAction`：那組型別是安全機制（檢舉／封鎖／Owner
/// 移除／刪除自己的內容）專屬的窮舉列舉，沒有「編輯」這個 case，硬塞進去會讓不相關的領域
/// （UGC 安全）背上「編輯」語意（見 `ContentActions.swift` 文件註解，`ContentAction` 四個 case
/// 全部是「安全／移除」動作，不是通用的內容操作表）。這裡改用兩個獨立的可選閉包：`onEdit`／
/// `onDelete` 皆為 nil 時（理論上不會發生——呼叫端只在至少一項可用時才呈現這張 sheet）只留
/// 「取消」，不特別處理成「空清單」的視覺（同 `ContentActionsSheet` 沒有為 0 動作設計特殊態
/// 的既有精神）。
///
/// 畫面級屬性（Notes `mfafV`→`UirG1`）：隱藏 Tab Bar ✗（sheet 呈現）；標題自訂 Head Title；
/// 釘底動作帶有（編輯／刪除／取消）；失敗文案鍵無（純導覽，選了之後才可能失敗，那是下一張
/// sheet 的事）；深色／AX3 未另畫分支，沿用共用 token。
struct GrowthRecordActionsSheet: View {
    let record: GrowthRecord
    /// nil＝不顯示「編輯這筆紀錄」列（不是作者，見 `GrowthRecordsListView.canEdit(_:)`）。
    var onEdit: (() -> Void)?
    /// nil＝不顯示「刪除這筆紀錄」列（既不是作者也不是 owner）。
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            grabber
            Text("\(record.measuredOnHistoryLabel)這筆紀錄")
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextSecondary)
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.bottom, AppSpacing.group)
            VStack(spacing: 0) {
                if let onEdit {
                    actionRow(icon: "pencil", label: "編輯這筆紀錄", isDanger: false, action: onEdit)
                }
                if onEdit != nil, onDelete != nil {
                    Divider().overlay(Color.lsBorder)
                }
                if let onDelete {
                    actionRow(icon: "trash", label: "刪除這筆紀錄", isDanger: true, action: onDelete)
                }
            }
            .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .padding(.horizontal, AppSpacing.screenPad)
            cancelButton
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.top, AppSpacing.group)
                .padding(.bottom, AppSpacing.section)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.lsBorder)
            .frame(width: 36, height: 5)
            .padding(.top, AppSpacing.block)
            .padding(.bottom, AppSpacing.tight)
            .accessibilityHidden(true)
    }

    private func actionRow(icon: String, label: String, isDanger: Bool, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(spacing: AppSpacing.group) {
                Image(systemName: icon).appIconFrame(.medium)
                Text(label).appFont(.body, weight: .semibold)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isDanger ? Color.lsDanger : Color.lsTextPrimary)
            .padding(.horizontal, AppSpacing.item)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
    }

    private var cancelButton: some View {
        Button {
            dismiss()
        } label: {
            Text("取消")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
    }
}

#if DEBUG
#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        GrowthRecordActionsSheet(
            record: GrowthRecord(
                id: UUID(), familyID: UUID(), childID: UUID(), authorID: GrowthStore.previewAuthorID,
                measuredOn: BirthdayFormat.date(fromWireString: "2026-08-20")!,
                heightCm: 78.5, weightKg: 9.6, headCm: 45.0, note: nil, createdAt: Date(), updatedAt: Date()
            ),
            onEdit: {}, onDelete: {}
        )
    }
}
#endif

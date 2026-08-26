import SwiftUI

/// `cmp/Approval Status`（LS-107，07／07a／07c 頁尾共用）：核准必開的鎖定狀態列。
///
/// 【LS-46 R3 使用者定案 #7「核准必開」】這裡原本設計是可切換的 `cmp/Approval Toggle`
/// （51×31 系統規格開關），已依定案改為不可互動的鎖定狀態列——沒有把手、沒有軌道、沒有
/// ON/OFF，VoiceOver 唸出來是一段陳述句，不是控件。**不綁 `Toggle` binding、不接受點擊**
/// （design/littlesprout.pen frame `PXPcH` Handoff Notes 原文）。07a「已關閉」態因此不存在
/// ——這是全稿唯一一種視覺狀態。
struct ApprovalStatusRow: View {
    var body: some View {
        HStack(spacing: AppSpacing.item) {
            Image(systemName: "lock.fill")
                .appIconFrame(.medium)
                .foregroundStyle(Color.lsTextPrimary)
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                Text("新成員一律要你核准才能進來")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                Text("為了保護家人隱私，這項設定固定開啟，無法關閉。")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
        }
        .padding(AppSpacing.item)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                .strokeBorder(Color.lsControlLine, lineWidth: 1)
        )
        // 陳述句，不是控件：VoiceOver 應該唸出一整段文字，不是「開關，開」這種控件語彙。
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ApprovalStatusRow()
        .padding()
}

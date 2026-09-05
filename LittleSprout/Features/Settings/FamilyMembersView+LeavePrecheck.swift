import SwiftUI

/// LS-152 / 03e 退出前置提示——拆成獨立檔案，理由同 `FamilyMembersView+Sheets.swift` 檔頭
/// 註解（R3 加入 `.soleMember` 變體後，那個檔案逼近 SwiftLint `file_length` 上限）。

/// 03e：唯一家庭管理者退出前置提示——R2（merge-review R1 M2）改成 push 整頁（稿 `sF5oA`
/// 是 Nav Back 頁面，不是 sheet；R1 誤用 `.sheet`）。R3（merge-review R2 M-A，orchestrator
/// 裁決 LS-192 comment `af82ed61-7f07-4be2-a332-3b1ede49e5c3`）：依 `FamilyStore
/// .leaveFlowCase` 分兩種內容（`Content`）：
/// - `.mustTransferFirst`（稿 `sF5oA`）：家庭還有其他成員，列出 Families Card（`Q4LlM`，
///   Phase 1 單一家庭 MVP 只畫一列）＋「前往轉移」導向成員列表（本票沒有另外的「選轉移對象」
///   畫面，pop 回 `FamilyMembersView` 讓使用者從成員列點 chevron 選人，那裡就有轉移入口）。
/// - `.soleMember`（設計稿無獨立板，記入 LS-208 補板）：家庭只剩自己一人，轉移無對象、退出
///   無意義——隱藏 Families Card（沒有「前往轉移」的對象），只留 Footer「返回設定」，文案改
///   導向「帳號」→「刪除帳號」（LS-24）。
///
/// 已知簡化（記入 handoff，N3 記 LS-96）：稿 Footer「返回設定」按鈕語意是回到設定頁根畫面
/// （跳過中間的 `FamilyMembersView`），但這支畫面目前掛在 `FamilyMembersView` 的
/// `.navigationDestination` 底下、共用同一個外層 `NavigationStack`，`dismiss()` 只會 pop
/// 一層回到 `FamilyMembersView`（使用者再按一次系統返回鈕才會回到設定頁）——要做到「一次跳
/// 兩層」需要把整個 Settings 導覽改成 `NavigationPath` 綁定的程式化導覽（現況全是
/// `NavigationLink` 直接推疊、沒有任何 `NavigationPath` 綁定可用，不是一行能改完，見
/// `LittleSprout/Features/SettingsView.swift` 既有的 `NavigationLink` 殼），範圍超出本輪
/// R3 修正，按鈕文字仍照稿寫「返回設定」，行為上是後退一層。
struct MustTransferOwnershipFirstView: View {
    /// R3（merge-review R2 M-A）：取代原本單一的 `otherMembersCount: Int` 參數——03e 現在有
    /// 兩種內容，`Hashable` 是 `navigationDestination(item:)` 的要求（見
    /// `FamilyMembersView.leavePrecheckContent`）。
    enum Content: Hashable {
        /// 稿 `sF5oA` 副標「家裡還有 3 位家人」——排除自己之後的其他成員數，由呼叫端
        /// （`FamilyMembersView`）算好傳入。
        case mustTransferFirst(otherMembersCount: Int)
        case soleMember
    }

    let familyName: String
    let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // R3（merge-review R2 N2）：改用 `ScrollableFillView`（同 02 `ProfileEditView` 既有
        // 慣例）——原本的裸 `ScrollView` 沒有把可視高度當 `minHeight` 撐開內容，`Spacer
        // (minLength:)` 因此完全不會把 Footer 往下推，「返回設定」緊貼在 Families Card 下方
        // 而不是稿 `sF5oA` 沉在頁底的版式（`n4mHAY` `height=fill_container`）。
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                if case .mustTransferFirst = content {
                    familiesCard
                        .padding(.top, AppSpacing.section)
                }
                Spacer(minLength: AppSpacing.item)
                footer
                    .padding(.top, AppSpacing.block)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
            .padding(.bottom, AppSpacing.block)
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text(title)
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text(subtitle)
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var title: String {
        switch content {
        case .mustTransferFirst: "需要先轉移家庭管理者身分"
        case .soleMember: "無法退出家庭"
        }
    }

    /// `.soleMember` 文案為 orchestrator 裁決原文逐字照抄（LS-192 comment
    /// `af82ed61-7f07-4be2-a332-3b1ede49e5c3`），標題「無法退出家庭」是本輪另外選的（裁決原文
    /// 只給了這句內文，沒有指定標題），對稱既有的直述句式標題。
    private var subtitle: String {
        switch content {
        case .mustTransferFirst(let otherMembersCount):
            "你是「\(familyName)」唯一的家庭管理者，家裡還有 \(otherMembersCount) 位家人。" +
            "退出之前，請先把家庭管理者身分交給其中一位。"
        case .soleMember:
            "目前家庭只有你一位成員，無法退出家庭。若要離開，請至「帳號」→「刪除帳號」。"
        }
    }

    /// 稿 `Q4LlM`（Families Card）只有一列（Phase 1 單一家庭 MVP）：icon＋家名＋「前往轉移」＋
    /// chevron，點擊 pop 回成員列表（見本型別文件註解）。只在 `.mustTransferFirst` 內容渲染。
    private var familiesCard: some View {
        SettingsCard {
            Button {
                dismiss()
            } label: {
                HStack(spacing: AppSpacing.group) {
                    Image(systemName: "person.2.fill")
                        .appIconFrame(.medium)
                        .foregroundStyle(Color.lsTextSecondary)
                    Text(familyName)
                        .appFont(.body, weight: .semibold)
                        .foregroundStyle(Color.lsTextPrimary)
                    Spacer(minLength: AppSpacing.group)
                    Text("前往轉移")
                        .appFont(.note)
                        .foregroundStyle(Color.lsTextSecondary)
                    Image(systemName: "chevron.right")
                        .appIconFrame(.small)
                        .foregroundStyle(Color.lsTextSecondary)
                }
                .padding(AppSpacing.insetCard)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
        }
    }

    private var footer: some View {
        Button {
            dismiss()
        } label: {
            Text("返回設定")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.controlPaddingMedium)
                .frame(minHeight: 48)
        }
    }
}

#if DEBUG
#Preview("03e 需先轉移") {
    NavigationStack {
        MustTransferOwnershipFirstView(familyName: "陳家", content: .mustTransferFirst(otherMembersCount: 3))
    }
}

#Preview("03e 單人變體") {
    NavigationStack {
        MustTransferOwnershipFirstView(familyName: "陳家", content: .soleMember)
    }
}
#endif

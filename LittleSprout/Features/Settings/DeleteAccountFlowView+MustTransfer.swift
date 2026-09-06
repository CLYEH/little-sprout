import SwiftUI

/// 04b 唯一 Owner 需轉移（`design/littlesprout.pen` `A4cVtH`）：LS-193——見
/// `DeleteAccountFlowView.swift` 檔頭對整組畫面拆檔理由的說明。
///
/// 「前往轉移」導向既有 `FamilyMembersView`（LS-192，Owner 視角，點成員列進 03c 轉移
/// sheet）——LS-152 Notes「04c 省略」段：刻意不另建一套選人 UI，完成轉移後回到這裡（系統
/// 返回鈕）重新檢查。Phase 1 單一家庭 MVP：`families` 通常只有一列（來自 `FamilyStore
/// .leaveFlowCase` 的 client 端預判，或伺服器 `LS050` 的 `DETAIL` 清單，見
/// `DeleteAccountFlowModel.performDeletion()`），列表結構已支援多列以對齊伺服器契約
/// （`DETAIL` 本身是陣列）。
struct MustTransferOwnershipBeforeDeletionView: View {
    let families: [FamilyPendingTransfer]
    let model: DeleteAccountFlowModel
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore
    let timelineStore: TimelineStore
    let albumsStore: AlbumsStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                header
                familiesCard
                    .padding(.top, AppSpacing.section)
                Spacer(minLength: AppSpacing.item)
                footer
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
            .padding(.bottom, AppSpacing.block)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("需要先轉移家庭管理者身分")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("你是下面這些家庭裡唯一的家庭管理者，而且家裡還有其他人。刪除帳號之前，請先把家庭管理者身分交給別人。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var familiesCard: some View {
        SettingsCard {
            ForEach(Array(families.enumerated()), id: \.element.id) { index, family in
                if index > 0 { SettingsRowDivider() }
                familyRow(family)
            }
        }
    }

    private func familyRow(_ family: FamilyPendingTransfer) -> some View {
        NavigationLink {
            FamilyMembersView(
                familyStore: familyStore, childrenStore: childrenStore,
                timelineStore: timelineStore, albumsStore: albumsStore
            )
        } label: {
            HStack(spacing: AppSpacing.group) {
                Image(systemName: "person.2.fill")
                    .appIconFrame(.medium)
                    .foregroundStyle(Color.lsTextSecondary)
                Text(family.familyName)
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
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
    }

    private var footer: some View {
        VStack(spacing: AppSpacing.group) {
            DeleteAccountSecondaryButton(
                icon: "arrow.clockwise", label: "我已完成轉移，重新檢查",
                action: model.recheckAfterTransfer, isLoading: model.isProcessing
            )
            DeleteAccountTextButton(label: "返回設定", action: { dismiss() })
        }
    }
}

#if DEBUG
#Preview("04b 唯一 Owner 需轉移") {
    NavigationStack {
        MustTransferOwnershipBeforeDeletionView(
            families: [FamilyPendingTransfer(familyID: UUID(), familyName: "陳家")],
            model: DeleteAccountFlowModel(
                accountAPIClient: PreviewAccountAPIClient(),
                familyStore: .preview(withFamily: Family(
                    id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
                )),
                authStore: .preview(), childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview()
            ),
            familyStore: .preview(withFamily: Family(
                id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
            )),
            childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview()
        )
    }
}
#endif

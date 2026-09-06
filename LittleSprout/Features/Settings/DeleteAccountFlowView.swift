import SwiftUI

/// 刪除帳號流程（LS-24，依 `design/littlesprout.pen` `LS-152` 04a–04h，LS-193）：`SettingsView`
/// 「帳號」區「刪除帳號」列的 `NavigationLink` 目的地（取代 LS-188 的最小佔位，見該檔文件
/// 註解）——本檔只是 root routing，實際七張畫面拆在 `DeleteAccountFlowView+MustTransfer.swift`
/// （04b）／`DeleteAccountFlowView+FinalConfirm.swift`（04e）／
/// `DeleteAccountFlowView+Status.swift`（04f／04g／04h），04a／04d 留在這裡（兩者版式最單純，
/// 檔案不會逼近 SwiftLint `file_length` 上限）。
///
/// 三分流（04a／04b／04d）重用 LS-192 `resolveLeaveFlowCase`「本人角色＋家庭成員數」判斷本體，
/// 不再另外寫一套判定——即時讀 `model.classification`，見 `DeleteAccountClassification`
/// 文件註解（含 merge-review R1 M1 訂正：`members` 尚未載回／載入失敗時顯式停在
/// `.pending`／`.membersLoadFailed`，絕不代打成 `.generalMember`）。
///
/// 04f／04g／04h 無系統導覽列（`DeleteAccountStep.showsNavigationBar`）；三分流與 04e 維持
/// 系統預設導覽列（含自動返回鈕）。
struct DeleteAccountFlowView: View {
    let childrenStore: ChildrenStore
    let timelineStore: TimelineStore
    let albumsStore: AlbumsStore

    @State private var model: DeleteAccountFlowModel

    init(
        accountAPIClient: AccountAPIClient,
        authStore: AuthStore,
        familyStore: FamilyStore,
        childrenStore: ChildrenStore,
        timelineStore: TimelineStore,
        albumsStore: AlbumsStore,
        eulaStore: EULAStore,
        resumer: PendingAccountDeletionResumer
    ) {
        self.childrenStore = childrenStore
        self.timelineStore = timelineStore
        self.albumsStore = albumsStore
        _model = State(initialValue: DeleteAccountFlowModel(
            accountAPIClient: accountAPIClient, familyStore: familyStore, authStore: authStore,
            childrenStore: childrenStore, timelineStore: timelineStore, albumsStore: albumsStore,
            eulaStore: eulaStore, resumer: resumer
        ))
    }

    var body: some View {
        content
            .appBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(model.step?.showsNavigationBar ?? true ? .automatic : .hidden, for: .navigationBar)
            // 同 `SettingsView`／`FamilyMembersView` 的補查慣例（見 `SettingsView.body` 文件
            // 註解）：`members` 已經有資料（不論是這裡查到還是 `SettingsView` 自己查到）就不
            // 重打一次——`classification` 是即時讀 `familyStore` 現況的計算屬性，不需要額外
            // 「重新分流」步驟，資料一到 SwiftUI 自然重繪。
            .task(id: model.familyStore.myFamily?.id) {
                guard model.familyStore.myFamily?.id != nil, model.familyStore.members.isEmpty else { return }
                await model.familyStore.refreshMembers()
            }
            // merge-review R2 B2：續傳呼叫（`finalizeAccountDeletion()`）搬出 `DeleteAccountFlowModel
            // .init`，改在畫面進場時觸發——`.task`（無 `id:`）只在這個 view identity 第一次出現時
            // 跑一次，`PendingAccountDeletionResumer.resumeIfPending(userID:)` 本身也有跨呼叫端的
            // in-flight 去重，兩層保護疊在一起，不會因為這支 view 重繪就重打 EF。
            .task {
                model.resumeIfNeeded()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let step = model.step {
            switch step {
            case .finalConfirm:
                FinalDeleteConfirmView(model: model)
            case .inProgress:
                DeletionInProgressView()
            case .completed:
                DeletionCompletedView(model: model)
            case .failed:
                DeletionFailedView(model: model)
            }
        } else {
            switch model.classification {
            case .pending:
                DeleteAccountMembersPendingView()
            case .membersLoadFailed(let error):
                DeleteAccountMembersLoadFailedView(error: error) {
                    Task { await model.familyStore.refreshMembers() }
                }
            case .generalMember:
                GeneralMemberDeleteAccountView(familyName: model.familyStore.myFamily?.name ?? "", model: model)
            case .mustTransferOwnership(let families):
                MustTransferOwnershipBeforeDeletionView(
                    families: families, model: model, familyStore: model.familyStore,
                    childrenStore: childrenStore, timelineStore: timelineStore, albumsStore: albumsStore
                )
            case .soleMember:
                SoleMemberDeleteWarningView(familyName: model.familyStore.myFamily?.name ?? "", model: model)
            }
        }
    }
}

// MARK: - 共用按鈕樣式（cmp/Button * 對應，見票文設計 handoff）

/// 外框 danger 按鈕（`cmp/Button Primary` 的 danger 變體：`$surface` 底、`$danger` 1.5pt 邊框，
/// icon＋label 皆 `$danger`）——04a／04d「繼續」、04e「永久刪除帳號」共用。push 畫面背景是
/// `.appBackground()`（漸層，不是 `$surface`），因此需要顯式 `.background(Color.lsSurface)`
/// 讓按鈕從漸層背景上「浮」出來——跟 `DeleteConfirmationSheet.confirmButton`（sheet 本身已經是
/// `$surface` 背景，按鈕不需要再疊一層）刻意不同，見兩者所在畫面的背景差異。
struct DeleteAccountDangerButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var isLoading = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.label) {
                if isLoading {
                    ProgressView().tint(Color.lsDanger)
                } else {
                    Image(systemName: icon).appIconFrame(.medium)
                }
                Text(label).appFont(.body, weight: .bold)
            }
            .foregroundStyle(Color.lsDanger)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.lsSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsDanger, lineWidth: 1.5)
            )
        }
        .disabled(isLoading)
    }
}

/// 純文字按鈕（`cmp/Button Text`：無底無邊框，`$text-primary`）——「先不要，返回設定」
/// 「返回設定」「取消」「聯絡我們」共用，同 `MustTransferOwnershipFirstView.footer` 的既有樣式。
struct DeleteAccountTextButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
    }
}

/// 實心 accent 主鈕（`cmp/Button Primary`）——04g「回到登入畫面」、04h「重試」共用。
struct DeleteAccountAccentButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var isLoading = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.label) {
                if isLoading {
                    ProgressView().tint(Color.lsOnAccent)
                } else {
                    Image(systemName: icon).appIconFrame(.medium)
                }
                Text(label).appFont(.body, weight: .bold)
            }
            .foregroundStyle(Color.lsOnAccent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.lsAccent)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
        .disabled(isLoading)
    }
}

/// 中性外框次要鈕（`cmp/Button Secondary`：`$control-line` 邊框，icon＋label `$text-primary`，
/// 無底）——04b「我已完成轉移，重新檢查」專用。
struct DeleteAccountSecondaryButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var isLoading = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.label) {
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: icon).appIconFrame(.medium)
                }
                Text(label).appFont(.body, weight: .semibold)
            }
            .foregroundStyle(Color.lsTextPrimary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
            )
        }
        .disabled(isLoading)
    }
}

// MARK: - 04a 一般成員（`VqMl0`／AX3 `dNED0`）

struct GeneralMemberDeleteAccountView: View {
    let familyName: String
    let model: DeleteAccountFlowModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                header
                infoList
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
            Text("刪除帳號")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("在你刪除帳號之前，請先看看接下來會發生什麼事。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var infoList: some View {
        VStack(alignment: .leading, spacing: AppSpacing.item) {
            infoItem(
                icon: "rectangle.portrait.and.arrow.right",
                text: familyName.isEmpty
                    ? "你會離開這個家庭，其他家人跟他們的照片、日記完全不受影響。"
                    : "你會離開「\(familyName)」，其他家人跟他們的照片、日記完全不受影響。"
            )
            // MJ-<informational>：lucide `image-off` 不在 LS-152 Notes SF Symbol 對照表內，
            // 沿用表內「image → photo」最近似映射，見 handoff「未完成」段。
            infoItem(
                icon: "photo",
                text: "你建立的相簿、日記與留言，以及你上傳的照片、影片，都會標記刪除；" +
                    "這個動作無法復原，這些內容會在 30 天內從我們的伺服器永久清除。"
            )
            infoItem(icon: "exclamationmark.triangle.fill", text: "帳號刪除完成後就無法復原，也無法用同一個帳號重新登入。")
        }
    }

    private func infoItem(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.group) {
            Image(systemName: icon)
                .appIconFrame(.medium)
                .foregroundStyle(Color.lsTextSecondary)
            Text(text)
                .appFont(.note)
                .foregroundStyle(Color.lsTextPrimary)
        }
    }

    private var footer: some View {
        VStack(spacing: AppSpacing.group) {
            DeleteAccountDangerButton(icon: "arrow.right", label: "繼續刪除帳號", action: {
                model.proceedToFinalConfirm(origin: .generalMember)
            })
            DeleteAccountTextButton(label: "先不要，返回設定", action: { dismiss() })
        }
    }
}

// MARK: - 04d 唯一成員警告（`Z6n16i`／AX3 `tWbae`）

struct SoleMemberDeleteWarningView: View {
    let familyName: String
    let model: DeleteAccountFlowModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .appFont(.display, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                warningCard
                    .padding(.top, AppSpacing.section)
                Text("如果你只是想休息一下，也可以先邀請家人加入，或直接把家庭留著、暫時不使用。")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
                    .padding(.top, AppSpacing.item)
                Spacer(minLength: AppSpacing.item)
                footer
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
            .padding(.bottom, AppSpacing.block)
        }
    }

    private var title: String {
        familyName.isEmpty ? "這會一併刪除你的家庭" : "這會一併刪除「\(familyName)」"
    }

    private var warningCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                HStack(spacing: AppSpacing.group) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .appIconFrame(.medium)
                        .foregroundStyle(Color.lsDanger)
                    Text("你是這個家庭唯一的成員")
                        .appFont(.body, weight: .bold)
                        .foregroundStyle(Color.lsDanger)
                }
                Text(bodyText)
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextPrimary)
            }
            .padding(AppSpacing.insetCard)
        }
    }

    private var bodyText: String {
        let name = familyName.isEmpty ? "這個家庭" : "「\(familyName)」"
        return "\(name)裡沒有其他人了。刪除你的帳號，會把整個家庭——所有照片、影片與日記——" +
            "一起永久刪除，這個動作無法復原，之後也沒有人能再打開這個家庭。"
    }

    private var footer: some View {
        VStack(spacing: AppSpacing.group) {
            DeleteAccountDangerButton(icon: "arrow.right", label: "我了解，繼續刪除", action: {
                model.proceedToFinalConfirm(origin: .soleMember)
            })
            DeleteAccountTextButton(label: "先不要，返回設定", action: { dismiss() })
        }
    }
}

#if DEBUG
#Preview("04a 一般成員") {
    NavigationStack {
        DeleteAccountFlowView(
            accountAPIClient: PreviewAccountAPIClient(), authStore: .preview(),
            familyStore: .preview(withFamily: Family(
                id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
            )),
            childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview(),
            eulaStore: .preview(shouldPresent: false), resumer: .preview()
        )
    }
}
#endif

import SwiftUI

/// `ForkView` 的停權／註冊關閉／刪除進行中出口，從 `ForkView.swift` 拆出獨立檔案——加完
/// M2（`suspendedOrRegistrationClosedError`）／M3（`accountDeletionInProgressError`）兩組鈕之後
/// 那支檔案超過 SwiftLint `file_length`／`type_body_length` 上限，理由同
/// `SettingsView+SignOut.swift` 從 `SettingsView.swift` 拆分的既有先例（merge-review R2 B3）。
/// `path`／`isSigningOut`／`signOutErrorMessage`（跨檔案 extension 存取不到 `private`）因此在
/// `ForkView.swift` 改成非 `private`，見該檔屬性宣告處註解。
///
/// 無對應設計稿（`design/littlesprout.pen` 沒有這個變體，已記入 LS-208 補板）：視覺沿用既有
/// `cmp/Button Text` 語彙（同 `EULAConsentView.disagreeButton`「不同意，登出」），不是自創版式。
extension ForkView {
    /// 「登出」——同 `AuthenticatedGate.disagreeAndSignOut()` 的既有作法（`authStore.signOut()`
    /// 會拋錯而非強制清 session，網路暫時失敗時讓使用者看得到錯誤、可以重試，不是
    /// `DeleteAccountFlowModel.forceSignOutLocally()` 那種「底層帳號已經被刪除、必須無論如何
    /// 清掉本地 session」的情境——這裡帳號還在，只是被停權，不該在網路失敗時假裝登出成功）。
    func signOutTapped() {
        guard !isSigningOut else { return }
        isSigningOut = true
        signOutErrorMessage = nil
        Task {
            defer { isSigningOut = false }
            do {
                try await authStore.signOut()
                familyStore.reset()
                childrenStore.reset()
                timelineStore.reset()
                albumsStore.reset()
                eulaStore.reset()
            } catch {
                signOutErrorMessage = AppError.map(error).userFacingMessage
            }
        }
    }

    // MARK: - 停權／註冊關閉／刪除進行中出口（merge-review R1 M2／M3）

    /// 兩種互斥成因、兩種鈕組合：
    /// - `FamilyStore.accountDeletionInProgressError`（`LS051`，M3）——`delete_my_account()`
    ///   RPC 在**另一台裝置**或**這台裝置重灌過 app**（本機 `PendingAccountDeletion` 旗標不在）
    ///   已經成功，只是 Edge Function 沒打完；鈕是「重試刪除」（語意：續傳，不是重新開始）。
    /// - `FamilyStore.suspendedOrRegistrationClosedError`（`LS052`／`LS054`，M2）——鈕是
    ///   「刪除帳號」（語意：從頭開始走三分流）。
    /// 兩者不會同時為真（同一組 `createFamilyState`／`requestJoinState` 錯誤碼只會是其中一種），
    /// 這裡用 `if let ... else if let ...` 而不是各自獨立渲染，避免萬一真的同時為真時疊出兩組
    /// 文案。排成一列而非疊放，呼應「登出」跟另一顆是兩個平行的出路，不是一主一次。
    @ViewBuilder
    var suspendedFooter: some View {
        if let error = familyStore.accountDeletionInProgressError {
            suspendedFooterBody(message: error.userFacingMessage) {
                retryDeletionButton
            }
        } else if let error = familyStore.suspendedOrRegistrationClosedError {
            suspendedFooterBody(message: error.userFacingMessage) {
                deleteAccountButton
            }
        }
    }

    @ViewBuilder
    private func suspendedFooterBody<Trailing: View>(
        message: String, @ViewBuilder trailingButton: () -> Trailing
    ) -> some View {
        VStack(spacing: AppSpacing.label) {
            Rectangle().fill(Color.lsBorder).frame(height: 1)
            Text(message)
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let signOutErrorMessage {
                Text(signOutErrorMessage)
                    .appFont(.note)
                    .foregroundStyle(Color.lsDanger)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: AppSpacing.group) {
                signOutButton
                trailingButton()
            }
        }
        .padding(.top, AppSpacing.item)
    }

    private var signOutButton: some View {
        Button(action: signOutTapped) {
            HStack(spacing: AppSpacing.tight) {
                if isSigningOut {
                    ProgressView()
                }
                Text("登出")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .disabled(isSigningOut)
    }

    private var deleteAccountButton: some View {
        Button {
            path.append(.deleteAccount)
        } label: {
            Text("刪除帳號")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsDanger)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
    }

    /// M3：先落地本機續傳旗標，再導去同一個 `.deleteAccount` route——`DeleteAccountFlowModel
    /// .init` 一建構就會讀到這個旗標，直接跳過三分流／04e，續傳到 04f 重打 Edge Function（見
    /// 該檔文件註解）。不需要另外造一套「只重試 EF」的畫面／model：這台裝置雖然沒有本機旗標，
    /// 但一旦落地，走的就是跟「同一台裝置、app 沒被殺掉」完全相同的續傳路徑。
    private var retryDeletionButton: some View {
        Button {
            if let userID = authStore.session?.userID {
                PendingAccountDeletion.markPending(userID: userID)
            }
            path.append(.deleteAccount)
        } label: {
            Text("重試刪除")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsDanger)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
    }
}

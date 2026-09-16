import SwiftUI
import UIKit

/// 06b 權限態・拒絕權限空狀態（`design/littlesprout.pen` LS-251 `PFvEX`／`Gxjee`／`iOZ0V`／
/// `d6bTWC`——Empty Print 家族：白邊＋對角兩顆角托＋兩道染料池＋壓印小字「看不到照片」，
/// R3 MN-13 全解，VR R4「值得保留」第 1 條「本票最好的一件事」）。
///
/// **已知視覺留白**（見 handoff 風險段）：本票沒有時間重現「Empty Print」母題本身的沖印品
/// 白邊／角托／染料池視覺元件（那是跨多票沿用的複雜自訂形狀，`PhotoCornerShape`／
/// `AlbumPhotoGridLayout` 這類既有元件是給「有照片」的沖印品格用，本畫面是「沒有照片」的
/// 空狀態），用系統圖示＋文字的素樸版本頂上，結構（無釘底動作帶、置中主鈕、左對齊內文、
/// AX3 縱向堆疊撐高、iPad 寬欄置中）與文案皆已對稿。
struct ImportPermissionDeniedView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(spacing: 0) {
            navRow
            Spacer(minLength: 0)
            emptyState
                // LS-251 R6 Notes「畫面級屬性」06b 列：iPad 834pt 寬——比 01/02/03 的 560pt
                // 置中欄寬（近全版），不是同一套窄欄規則。
                .frame(maxWidth: horizontalSizeClass == .regular ? 834 : .infinity)
            Spacer(minLength: 0)
        }
        .appBackground()
    }

    private var navRow: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                HStack(spacing: AppSpacing.tight) {
                    Image(systemName: "chevron.left").appIconFrame(.medium).accessibilityHidden(true)
                    Text("取消").appFont(.body, weight: .semibold)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .foregroundStyle(Color.lsTextPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, AppSpacing.label)
    }

    // MARK: - Empty Print（素樸版本，見型別文件註解）

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                Text("新增照片").appFont(.display, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: AppSpacing.block) {
                Image(systemName: "photo.badge.exclamationmark")
                    .appIconFrame(.large)
                    .foregroundStyle(Color.lsTextSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppSpacing.label) {
                    Text("還沒有取用照片的權限。")
                        .appFont(.body, weight: .semibold)
                        .foregroundStyle(Color.lsTextPrimary)
                    Text("開啟「照片」權限後，就能從相機膠卷批次匯入舊照片與影片。")
                        .appFont(.note)
                        .foregroundStyle(Color.lsTextSecondary)
                }
                .multilineTextAlignment(.leading)
                openSettingsButton
            }
            .padding(AppSpacing.item)
            .background(Color.lsSurface2, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        }
        .padding(.horizontal, AppSpacing.screenPad)
    }

    private var openSettingsButton: some View {
        Button {
            openSettings()
        } label: {
            Text("開啟「照片」權限")
                .appFont(.body, weight: .bold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.controlPaddingCTA)
        }
        .foregroundStyle(Color.lsOnAccent)
        .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
    }

    /// 已拒絕的相片庫權限只能到系統設定改——`PHPhotoLibrary.requestAuthorization` 對已決定
    /// 過的狀態不會重新彈窗（系統行為），跟 06a 的 `presentLimitedLibraryPicker`（可在 app
    /// 內管理「已選取的照片」清單）是兩條不同的路，見 `ImportOrganizeView.limitedLibraryBanner`
    /// 文件註解。
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#if DEBUG
#Preview {
    ImportPermissionDeniedView()
}
#endif

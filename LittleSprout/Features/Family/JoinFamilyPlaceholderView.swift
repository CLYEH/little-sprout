import SwiftUI

// LS-108：輸入邀請碼（06）＋等待核准（06d）＋deep link 承接＋owner 審核清單，這些都是「加入
// 路徑」（B），本票（LS-107，Owner 路徑）明確排除（見票文 Scope 第 5 點）。這個畫面只是三岔路
// 「我有邀請碼」卡的暫時導航終點，讓 A 票的 tap target 有地方可去，不是 06 的實作。
struct JoinFamilyPlaceholderView: View {
    var body: some View {
        ScrollableFillView {
            VStack(spacing: AppSpacing.item) {
                Image(systemName: "qrcode")
                    .appIconFrame(.large)
                    .foregroundStyle(Color.lsTextSecondary)
                Text("輸入邀請碼")
                    .appFont(.display, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                Text("這個畫面即將推出，敬請期待。")
                    .appFont(.body)
                    .foregroundStyle(Color.lsTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(AppSpacing.screenPad)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        JoinFamilyPlaceholderView()
    }
}

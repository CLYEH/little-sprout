import SwiftUI

/// `SettingsView` 拆分出的「個人」列與 iPad sidebar 五區支援型別——`SettingsView.swift` 加完
/// LS-188 五區內容後超過 SwiftLint `file_length` 上限，理由同 `InviteFamilyView+Role.swift`
/// 從 `InviteFamilyView.swift` 拆分的既有慣例。`SettingsView` 是這幾個型別目前唯一的呼叫端，
/// 因此不再標 `private`（跨檔案要能引用），但仍不對外公開任何 API 意圖。

/// LS-345：`profileSection`（`SettingsView.swift`）呼叫端要接上的頭像 URL——抽成獨立、非
/// `private` 的計算屬性單純是為了讓單元測試能直接核對「有 `avatarURL` 的 profile 進到這裡後
/// 頭像來源非空」這條線有接上（`SettingsView.swift` 貼近 SwiftLint `file_length` 上限，見上方
/// 檔頭註解，本體留在 `profileSection`，這裡只放這顆屬性）。
extension SettingsView {
    var profileAvatarURL: URL? {
        familyStore.avatarDisplayURL(rawValue: familyStore.myProfile?.avatarURL)
    }
}

/// Regular（iPad）sidebar 的五區——與五個 `SettingsSectionBlock` 一一對應。跟 app 層
/// `AppSection`（時間軸／相簿／寶貝／設定）是兩層不同的導覽狀態，故意不合併：合併會讓
/// 「設定」這個 tab 的內部子導覽跟 app 層的 tab 選取耦合，其餘三個 tab 沒有這個概念。
enum SettingsSection: CaseIterable, Identifiable {
    case profile, family, contentSafety, legal, account

    var id: Self { self }

    var title: String {
        switch self {
        case .profile: "個人"
        case .family: "家庭"
        case .contentSafety: "內容與安全"
        case .legal: "法律"
        case .account: "帳號"
        }
    }

    /// 稿面 `B2DckT` Nav Item 對照表：user-round／users／shield／file-text／trash-2
    /// （lucide）→ person.crop.circle／person.2.fill／shield／doc.text／trash（SF Symbol）。
    var icon: String {
        switch self {
        case .profile: "person.crop.circle"
        case .family: "person.2.fill"
        case .contentSafety: "shield"
        case .legal: "doc.text"
        case .account: "trash"
        }
    }
}

/// 稿面「Section 個人」等區塊殼：`$fs-meta`(13pt) 灰字段落標題＋`SettingsCard`。
struct SettingsSectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text(title)
                .appFont(.meta, weight: .semibold)
                .tracking(0.3)
                .foregroundStyle(Color.lsTextSecondary)
            SettingsCard {
                content
            }
        }
    }
}

/// 稿面「個人」列——`cmp/Profile Print`（`OePXK`，two-corner 沖印品母題，見
/// `little-sprout-brand` skill「角托三段規則」）＋姓名＋固定副標「編輯顯示名稱與頭像」。
/// 跟其餘列不同（沒有用 `SettingsRowView`）：左側是頭像沖印框而不是 SF Symbol icon。
struct ProfileSummaryRow: View {
    let displayName: String
    /// LS-345：`profiles.avatar_url` 已簽好的可顯示 URL（呼叫端傳 `familyStore
    /// .avatarDisplayURL(rawValue:)` 的結果，同 `FamilyMembersView`／`BlockListView` 既有
    /// 慣例）；nil 時 `ProfilePrintChip` 退回 SF Symbol 佔位。
    var avatarURL: URL?

    var body: some View {
        HStack(spacing: AppSpacing.group) {
            ProfilePrintChip(avatarURL: avatarURL)
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                Text(displayName)
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                Text("編輯顯示名稱與頭像")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
            Spacer(minLength: AppSpacing.group)
            Image(systemName: "chevron.right")
                .appIconFrame(.small)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .padding(AppSpacing.insetCard)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// `cmp/Profile Print`（`OePXK`）60×60 沖印小卡：`$print-paper` 底＋45×45 相片區＋兩顆對角角托
/// （16.4pt，`PhotoCornerShape` 既有形狀，只取 topLeading／bottomTrailing 兩個，對應稿面
/// `GEBcf` ref 的 Mount TL／Mount BR）。「加入於 YYYY/M」壓印字未實作：那需要 `profiles
/// .created_at`，同樣是 02 頁的範圍，見 `SettingsView.displayName` 文件註解——記入 handoff
/// 「未完成」。
///
/// **LS-345**：45×45 相片區改吃 `avatarURL`——有值就顯示照片，沒有（或簽名還沒回來）退回
/// SF Symbol 佔位（同 `ChildAvatarView`／LS-67 E3「有圖顯示圖／無圖顯示縮寫」既有先例）。
/// `AsyncImage` 直接掛在 `ZStack` 裡、不包在 `if let avatarURL` 條件分支內——同
/// `ChildAvatarView` 文件註解點名的 LS-273 教訓（`avatarURL` 由 nil 變成非 nil 時若靠
/// `if let` 新建 `AsyncImage`，換頭像後的下載 task 可能被同一瞬間的 transition 取消且不重試）。
/// 呼叫端目前只有 `ProfileSummaryRow`（設定頁「個人」列）真的傳非 nil 值；留言列表
/// （`CommentsSheetView+List`／`+Footer`）與按讚名單（`LikersListSheet`）依 LS-177 Notes
/// `MJ-1` 定案一律顯示佔位、不傳 `avatarURL`（票文範圍 3 核可稿沒畫頭像，本票不加）。
///
/// LS-216：加 `size` 參數（預設 60，既有呼叫端 `ProfilePrintChip()` 行為不變）——LS-177
/// Handoff Notes `d5RNKR`「AX3 頭像／送出鈕覆寫」定案 `scale = size/60`（元件原生 60px
/// 基準），本檔所有幾何值（相片邊長 45／內距 7.5／外框圓角 6／相片圓角 2／角托邊長
/// 16.4／角托外移 3.8）等比例縮放；按讚名單 sheet（`LikersListSheet`）用 `size: 40`
/// （scale 0.667），對照 `bsbDd` 的 `Get` 實測 override 值（`lOPO7` 40×40 圓角 4／`MN0WF`
/// 30×30 圓角 1.333／角托 10.93／外移 2.53）逐一核對過一致。
struct ProfilePrintChip: View {
    var size: CGFloat = 60
    /// LS-345：見型別文件註解「LS-345」段。
    var avatarURL: URL?

    private var scale: CGFloat { size / 60 }
    private var cornerSize: CGFloat { 16.4 * scale }
    private var cornerOut: CGFloat { 3.8 * scale }

    var body: some View {
        ZStack {
            Color.lsSurface2
            AsyncImage(url: avatarURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    placeholderIcon
                }
            }
        }
        .frame(width: 45 * scale, height: 45 * scale)
        .clipShape(RoundedRectangle(cornerRadius: 2 * scale))
        .padding(7.5 * scale)
        .background(Color.lsPrintPaper)
        .clipShape(RoundedRectangle(cornerRadius: 6 * scale))
        .overlay(corner(.topLeading, alignment: .topLeading, out: -cornerOut))
        .overlay(corner(.bottomTrailing, alignment: .bottomTrailing, out: cornerOut))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var placeholderIcon: some View {
        Image(systemName: "person.fill")
            .font(.system(size: 22 * scale))
            .foregroundStyle(Color.lsTextSecondary.opacity(0.5))
    }

    private func corner(_ corner: PhotoCorner, alignment: Alignment, out: CGFloat) -> some View {
        let shape = PhotoCornerShape(corner: corner)
        return ZStack {
            shape.fill(Color.lsPhotoCorner)
            shape.foldEdge(in: CGRect(x: 0, y: 0, width: cornerSize, height: cornerSize))
                .stroke(Color.lsCornerFold, lineWidth: 1)
        }
        .frame(width: cornerSize, height: cornerSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .offset(x: out, y: out)
    }
}

#if DEBUG
#Preview {
    ProfileSummaryRow(displayName: "陳美玲")
        .padding()
}
#endif

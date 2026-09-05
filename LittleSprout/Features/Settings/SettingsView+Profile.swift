import SwiftUI

/// `SettingsView` 拆分出的「個人」列與 iPad sidebar 五區支援型別——`SettingsView.swift` 加完
/// LS-188 五區內容後超過 SwiftLint `file_length` 上限，理由同 `InviteFamilyView+Role.swift`
/// 從 `InviteFamilyView.swift` 拆分的既有慣例。`SettingsView` 是這幾個型別目前唯一的呼叫端，
/// 因此不再標 `private`（跨檔案要能引用），但仍不對外公開任何 API 意圖。

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

    var body: some View {
        HStack(spacing: AppSpacing.group) {
            ProfilePrintChip()
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

/// `cmp/Profile Print`（`OePXK`）60×60 沖印小卡：`$print-paper` 底＋45×45 相片區（目前沒有
/// 真實頭像資料，見 `SettingsView.displayName` 文件註解，用 SF Symbol 占位）＋兩顆對角角托
/// （16.4pt，`PhotoCornerShape` 既有形狀，只取 topLeading／bottomTrailing 兩個，對應稿面
/// `GEBcf` ref 的 Mount TL／Mount BR）。「加入於 YYYY/M」壓印字未實作：那需要 `profiles
/// .created_at`，同樣是 02 頁的範圍，見 `SettingsView.displayName` 文件註解——記入 handoff
/// 「未完成」。
struct ProfilePrintChip: View {
    private let cornerSize: CGFloat = 16.4
    private let cornerOut: CGFloat = 3.8

    var body: some View {
        ZStack {
            Color.lsSurface2
            Image(systemName: "person.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.lsTextSecondary.opacity(0.5))
        }
        .frame(width: 45, height: 45)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .padding(7.5)
        .background(Color.lsPrintPaper)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(corner(.topLeading, alignment: .topLeading, out: -cornerOut))
        .overlay(corner(.bottomTrailing, alignment: .bottomTrailing, out: cornerOut))
        .frame(width: 60, height: 60)
        .accessibilityHidden(true)
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

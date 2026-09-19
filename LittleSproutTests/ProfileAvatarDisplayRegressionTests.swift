import SwiftUI
@testable import LittleSprout
import XCTest

/// LS-345：使用者實機回報「個人資料有放大頭照，但設定頁沒顯示我的照片」——`profiles
/// .avatar_url` 上傳與寫入都成功（正式站唯讀查證實），問題在 client 顯示端：`SettingsView`
/// 「個人」列（`ProfileSummaryRow` → `ProfilePrintChip`）從沒把 `familyStore.myProfile
/// .avatarURL` 接進去，`ProfilePrintChip` 本身也還沒有 `avatarURL` 參數——這裡不是新鮮度
/// 問題，是從沒接線。
///
/// `profileAvatarURL`（`SettingsView+Profile.swift`）是把這條線變成可以單元測試的「view
/// model」層——同 `FamilyStore.avatarDisplayURL(rawValue:)` 本身已有的測試（`FamilyStoreProfileTests`）
/// 互補：那支測試釘住「原始欄位值 → 可顯示 URL」的轉換規則，這裡釘住「`SettingsView` 真的把
/// `myProfile.avatarURL` 餵給這個轉換」。
@MainActor
final class ProfileAvatarDisplayRegressionTests: XCTestCase {
    private func makeSettingsView(familyStore: FamilyStore) -> SettingsView {
        SettingsView(
            authStore: .preview(),
            familyStore: familyStore,
            childrenStore: .preview(),
            accountAPIClient: PreviewAccountAPIClient(),
            timelineStore: .preview(),
            albumsStore: .preview(),
            eulaStore: .preview(shouldPresent: false),
            resumer: .preview(),
            safetyAPIClient: PreviewSafetyAPIClient(),
            pushNotificationStore: .preview()
        )
    }

    /// mutation：把 `profileAvatarURL` 改回恆回傳 `nil`（或拿掉對 `familyStore.avatarDisplayURL`
    /// 的呼叫），這支測試會抓到——OAuth 網址不需要簽名快取，直接就能驗證這條線有接上。
    func test_profileAvatarURL_reflectsMyProfileAvatarURL() {
        let familyStore = FamilyStore.preview()
        familyStore.seedProfileForPreview(
            Profile(id: UUID(), displayName: "陳美玲", avatarURL: "https://lh3.googleusercontent.com/a/avatar.jpg")
        )
        let view = makeSettingsView(familyStore: familyStore)

        XCTAssertEqual(view.profileAvatarURL, URL(string: "https://lh3.googleusercontent.com/a/avatar.jpg"))
    }

    /// 沒有頭像（`myProfile` 為 nil，或 `avatarURL` 為 nil）時要回 nil，讓 `ProfilePrintChip`
    /// 退回 SF Symbol 佔位——不能因為抽出這條線之後誤把「還沒查到 profile」畫成有頭像。
    func test_profileAvatarURL_nilWhenNoProfileOrNoAvatar() {
        let noProfileStore = FamilyStore.preview()
        XCTAssertNil(makeSettingsView(familyStore: noProfileStore).profileAvatarURL)

        let noAvatarStore = FamilyStore.preview()
        noAvatarStore.seedProfileForPreview(Profile(id: UUID(), displayName: "陳美玲", avatarURL: nil))
        XCTAssertNil(makeSettingsView(familyStore: noAvatarStore).profileAvatarURL)
    }

    /// 沒有 ViewInspector 測不到 `profileSection`（`private`、`@ViewBuilder`）實際渲染出的
    /// 樹（同 `GrowthDetailViewerGatingRegressionTests`／`GrowthIdentityFreshnessRegressionTests`
    /// 文件註解點名的既有理由），這裡用原始碼文字守衛。
    ///
    /// **LS-345 R2（merge-review R1 m1）**：這條線改成兩段——`profileSection`
    /// （`SettingsView.swift`）呼叫 `profileSummaryRowWithAvatarRefresh(displayName:)`（放到
    /// `SettingsView+Profile.swift` 是檔案行數理由，見該檔文件註解），這顆函式內部才真的組
    /// `ProfileSummaryRow(displayName:avatarURL:)`。兩段都要各自守，任一段被拿掉都要紅。
    ///
    /// mutation：把 `profileSection` 改回直接呼叫
    /// `ProfileSummaryRow(displayName: displayName)`（不經 `profileSummaryRowWithAvatarRefresh`，
    /// LS-345 之前的舊寫法），或把 `profileSummaryRowWithAvatarRefresh` 內部改回不帶
    /// `avatarURL:`，這支測試都會抓到。
    func test_profileSection_passesProfileAvatarURLToProfileSummaryRow() throws {
        let settingsViewSource = try sourceText(relativePath: "LittleSprout/Features/SettingsView.swift")
        let profileExtensionSource = try sourceText(
            relativePath: "LittleSprout/Features/Settings/SettingsView+Profile.swift"
        )

        XCTAssertTrue(
            settingsViewSource.contains("profileSummaryRowWithAvatarRefresh(displayName: displayName)"),
            "profileSection 要透過 profileSummaryRowWithAvatarRefresh(displayName:) 顯示「個人」列"
        )
        let expectedCall = "ProfileSummaryRow(displayName: displayName, avatarURL: profileAvatarURL)"
        XCTAssertTrue(
            profileExtensionSource.contains(expectedCall),
            "profileSummaryRowWithAvatarRefresh 要把 profileAvatarURL 轉手給 ProfileSummaryRow，否則設定頁" +
                "「個人」列永遠顯示 SF Symbol 佔位，即使 profiles.avatar_url 已經有值"
        )
    }

    private func sourceText(relativePath: String, file: StaticString = #filePath) throws -> String {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let worktreeRoot = testFileURL
            .deletingLastPathComponent() // LittleSproutTests/
            .deletingLastPathComponent() // worktree 根目錄
        let sourceURL = worktreeRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

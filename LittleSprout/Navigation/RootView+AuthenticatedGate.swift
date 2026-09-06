import SwiftUI

/// LS-107：已登入之後，先確定「有沒有家庭」才知道要進三岔路（`ForkView`）還是主畫面
/// （`AuthenticatedRootView`）——`familyStore.myFamily` 是這個判斷的唯一依據，建立家庭
/// 成功後它會被直接設成新家庭，這裡下一次重繪就自動切到主畫面，不需要任何手動導航
/// （見 `FamilyStore` 文件註解／LS-18 comment `1fce1645`）。
///
/// 查詢失敗時刻意不當成「沒有家庭」處理：那樣會讓已經有家庭、只是網路暫時失敗的使用者被
/// 誤導進三岔路、看起來像能重新建立一個家庭。
///
/// R1 F1：`.task(id: authStore.session?.userID)`——不是單純的 `.task { if lookupState ==
/// .idle { ... } }`。`familyStore` 隨 app 存活，登出不會重置它；若只看 `lookupState`，
/// 第二位在同一台裝置登入的使用者會因為 store 裡還殘留第一位的 `.success` 狀態而被整個
/// 跳過查詢，直接沿用第一位的家庭與邀請碼。這裡改成每次 user id 變動都呼叫
/// `familyStore.syncOwner(to:)`——id 不同就先歸零再視情況重查，見該方法文件註解。
///
/// R2 N5 訂正：「登出」不是這支 `.task(id:)` 處理的——`AuthenticatedGate` 本身（連同這個
/// `.task`）會在 `authStore.isAuthenticated()` 變 false 的當下整個被 `RootView.body` 移出畫面
/// 樹，`.task(id:)` 只會被**取消**，不會再以 `id: nil` 重新啟動一次；`syncOwner(to: nil)`
/// 因此在這條路徑上永遠不會被呼叫到。登出時真正負責歸零 `FamilyStore` 的是
/// `SettingsView.signOut()` 成功後直接呼叫的 `familyStore.reset()`——兩個入口分工：這裡管
/// 「已登入狀態下換人／首次登入」，登出清理是另一條路徑。
///
/// LS-190：`eulaStore.shouldPresent` 在 `familyStore` 查詢之前把關——`EULAConsentView` 取代
/// 整個已登入畫面樹（含家庭查詢／`ForkView`／主畫面），版本不符或從未同意過時，使用者看不到
/// 任何家庭相關內容，直到按下「我已閱讀並同意」或「不同意，登出」為止。兩支 `.task(id:)`
/// （EULA 檢查／家庭查詢）各自獨立併行送出，不因為 EULA 尚未確認就延後家庭查詢的網路往返
/// ——`shouldPresent == false` 時家庭查詢多半早已跑完，使用者同意後幾乎無感切換到主畫面。
///
/// 非 `private`（LS-190 起）：`TapTargetGateHarness.eulaConsentToTimelineHost` 需要直接建構
/// 這個型別，才能用 harness 走完整「EULA 出現 → 同意 → 進時間軸」流程（`.eulaConsent` 那個
/// harness case 只掛了 `EULAConsentView` 本體，接不到「同意後切換到主畫面」這段反應式邏輯，
/// 那段邏輯只存在這裡）——同 `AuthenticatedRootView`（`.sectionTabView` 系列 host 用的）本來
/// 就不是 `private` 的既有先例。
struct AuthenticatedGate: View {
    let authStore: AuthStore
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore
    let timelineStore: TimelineStore
    let albumsStore: AlbumsStore
    let eulaStore: EULAStore
    let diaryAPIClient: DiaryAPIClient
    let mediaUploadService: MediaUploadService
    @Binding var pendingInviteCode: String?

    var body: some View {
        Group {
            if let userID = authStore.session?.userID {
                eulaGate(userID: userID)
            } else {
                // `RootView.body` 只在 `authStore.isAuthenticated()` 為 true 時才會顯示這個
                // 型別，理論上 `session` 一定非 nil；這裡純粹是型別安全的防禦分支，不對應任何
                // 實際會走到的產品狀態。
                ProgressView()
            }
        }
        // LS-190 R2 informational-5（merge-review R1）：這兩支 `.task(id:)` 刻意併行送出，
        // 不因為 EULA 尚未確認就延後家庭查詢的網路往返——`eulaGate` 已經確保使用者在 EULA
        // 未知／需要顯示期間看不到任何家庭內容（把關在畫面層，不是在「要不要發請求」這一層），
        // `shouldPresent == false` 時家庭查詢多半早已跑完，同意後幾乎無感切換。裁定維持現狀
        // ：效能取捨，不是遺漏。
        .task(id: authStore.session?.userID) {
            guard let userID = authStore.session?.userID else { return }
            await eulaStore.checkStatus(userID: userID)
        }
        .task(id: authStore.session?.userID) {
            await familyStore.syncOwner(to: authStore.session?.userID)
        }
    }

    /// LS-190 R2（merge-review R1 B2(b)）：判斷順序改成先看「這組結果是不是屬於 `userID`
    /// 這位目前登入者」——`eulaStore.isKnown(for:)` 把 `.submitting` 與換帳號後
    /// `judgedUserID` 還沒更新這兩種情況都視為「未知」，一律先擋在 loading，不會沿用上一位
    /// 使用者殘留的 `shouldPresent == false` 誤放行到家庭查詢。`.failure` 只在屬於目前
    /// `userID` 時才顯示重試（同一個原因：換帳號瞬間可能還看得到上一位使用者失敗的殘留
    /// `checkState`，那個失敗不該被當成「這位使用者」的失敗）。
    @ViewBuilder
    private func eulaGate(userID: UUID) -> some View {
        if case .failure(let error) = eulaStore.checkState, eulaStore.judgedUserID == userID {
            // 重用 `FamilyLookupFailedView`（純泛型「訊息＋重試鈕」畫面，見該檔）——同一種
            // 網路失敗兜底樣式，不需要另外造一份幾乎一樣的畫面。
            FamilyLookupFailedView(message: error.userFacingMessage) {
                Task { await eulaStore.checkStatus(userID: userID) }
            }
        } else if !eulaStore.isKnown(for: userID) {
            ProgressView("正在確認條款狀態…")
        } else if eulaStore.shouldPresent == true {
            EULAConsentView(eulaStore: eulaStore, onDisagree: disagreeAndSignOut)
        } else {
            familyGate
        }
    }

    @ViewBuilder
    private var familyGate: some View {
        switch familyStore.lookupState {
        case .idle, .submitting:
            ProgressView("正在確認你的家庭…")
        case .failure(let error):
            FamilyLookupFailedView(message: error.userFacingMessage) {
                Task { await familyStore.refreshMyFamily() }
            }
        case .success:
            if familyStore.myFamily != nil {
                AuthenticatedRootView(
                    authStore: authStore, familyStore: familyStore, childrenStore: childrenStore,
                    timelineStore: timelineStore, albumsStore: albumsStore, eulaStore: eulaStore,
                    diaryAPIClient: diaryAPIClient, mediaUploadService: mediaUploadService
                )
            } else {
                ForkView(authStore: authStore, familyStore: familyStore, pendingInviteCode: $pendingInviteCode)
            }
        }
    }

    /// 「不同意」的收尾——同 `SettingsView.signOut()` 既有的四個 store 歸零清單（見該檔），
    /// 額外多歸零 `eulaStore`（換帳號登入需要重新檢查，不能沿用上一位使用者的
    /// `shouldPresent`）。刻意不共用同一份程式碼：`SettingsView` 是使用者已在主畫面內的登出
    /// 入口，這裡是 EULA 閘門專屬的另一條路徑，兩處各自持有的 store 引用範圍不同（這裡沒有
    /// `SettingsView` 的 `errorMessage`／`isSigningOut` 那層 UI 狀態，改用 `throws` 讓
    /// `EULAConsentView` 自己處理錯誤顯示）。
    private func disagreeAndSignOut() async throws {
        try await authStore.signOut()
        familyStore.reset()
        childrenStore.reset()
        timelineStore.reset()
        albumsStore.reset()
        eulaStore.reset()
    }
}

/// 查詢「我的家庭」失敗（多半是網路）時的重試畫面——沒有對應的 .pen 設計稿：這是一個純技術性
/// 的錯誤兜底，不是產品要求的畫面，維持最簡單的系統風格文字＋按鈕，不套用沖印品母題。
private struct FamilyLookupFailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.item) {
            Text(message)
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
                .multilineTextAlignment(.center)
            Button("重試", action: retry)
                .appFont(.body, weight: .semibold)
        }
        .padding(AppSpacing.screenPad)
    }
}

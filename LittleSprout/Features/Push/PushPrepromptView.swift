import SwiftUI

/// 推播權限前置說明頁（LS-217，依 `design/littlesprout.pen` `j7WwV`／`ckgMp`／`KyxGc`；
/// Handoff Notes `EclPC` 節「推播權限前置說明頁與系統對話框」）——Apple 建議的
/// pre-permission prompt 模式：先解釋「為什麼要通知」，使用者主動按「開啟通知」才觸發系統
/// 對話框（`FeqWk`，票文「不實作」，見 Notes `j7RFGF`：那是系統原生 chrome，App 無法自訂
/// 樣式，呼叫 `UNUserNotificationCenter.requestAuthorization` 後系統自動顯示，可能與稿面視覺
/// 細節不同，屬預期差異）。
///
/// 兩個呼叫端共用同一份 View（`onFinish` 由呼叫端決定關閉後要做什麼）：
///   - `AuthenticatedRootView`：登入後首次進時間軸自動顯示（`PushNotificationStore
///     .refreshForEnteringApp`／`.showsPreprompt`），`onFinish` 呼叫
///     `pushNotificationStore.dismissPreprompt(userID:)` 標記「已看過」。
///   - `SettingsView`：「推播通知」列在 `.notDetermined` 態被點擊時重新導向（票文範圍 3
///     「走第 1 項流程」）——這條路徑**不**受「已看過」旗標限制，`onFinish` 只需要關閉
///     `.fullScreenCover`，不呼叫 `dismissPreprompt`（該旗標只管「自動顯示」這件事，見
///     `PushPrepromptPolicy` 文件註解）。
struct PushPrepromptView: View {
    let pushNotificationStore: PushNotificationStore
    let onFinish: () -> Void

    /// 稿面 `KyxGc`（AX3）把通知預覽卡加寬到 340（一般態 275）、出血位移改成 `x:5`（一般態
    /// `x:70`）、Hero Stack 高度改成 325（一般態 225）——AX3 body 放大後兩行內文在 275 寬會
    /// 換成三行甚至更多，稿面刻意加寬避免不必要的換行（Notes `f6x5i`「MJ-4／MJ-2／MJ-3」段）。
    /// `DynamicTypeSize.isAccessibilitySize` 涵蓋 AX1–AX5，稿面只畫了 AX3 這一檔，這裡把同一
    /// 套加寬視為整個 accessibility 範圍共用（沒有理由 AX1／AX2 不加寬、AX3 才加寬）。
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// AX3（`KyxGc`）把通知卡加寬到 340／Hero Stack 拉高到 325 之後，內容總高度在真實裝置的
    /// 852pt 高螢幕上會超出可視範圍（稿面本身也是拉高整塊板到 1454pt 高，不是硬塞進一個
    /// 852pt 高的畫面）——模擬器實測：原本的「`content`＋`Spacer`＋`footer`」固定版面在 AX3
    /// 下會把 CTA／「稍後再說」擠出螢幕外、完全不可達，違反十條 #7「每張重要畫面必附 AX3
    /// 壓力板」的前提（畫面本身要撐得住，不是畫出來就好）。
    ///
    /// **兩顆按鈕固定在 `ScrollView` 之外**（同 `DeleteConfirmationSheet` 既有先例、同一份
    /// 檔頭引註的 merge-review 教訓）：先試過 `.safeAreaInset(edge: .bottom)`
    /// （`EULAConsentView` 的既有寫法），模擬器實測 AX3 下 footer 疊在捲動內容中段、兩者互相
    /// 穿插重疊——這個畫面是 `TapTargetGateHarness` 直接掛的最外層根視圖（不像
    /// `EULAConsentView` 掛在 `AuthenticatedGate` 底下），`safeAreaInset` 在「本身就是 scene
    /// root」時似乎沒有可靠的外層安全區可以疊加（未進一步深究確切成因，兩個檔案的巢狀深度
    /// 不同是唯一觀察到的差異）。改用 `VStack { ScrollView { content }; footer }`（footer 是
    /// `ScrollView` 的一般手足、不是安全區疊加）——`ScrollView` 拿到 `VStack` 分配剩餘空間，
    /// `footer` 拿它自己的自然高度，兩者不會互相穿插；一般字級下內容撐不滿一頁，視覺效果與
    /// 原本的 `Spacer` 版面一致；AX3／更大字級下內容可以捲動，CTA／「稍後再說」永遠可達且
    /// 不隨捲動移動。
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .padding(.horizontal, AppSpacing.screenPad)
            }
            footer
                .padding(.horizontal, AppSpacing.screenPad)
        }
        .appBackground()
    }

    private var content: some View {
        VStack(spacing: AppSpacing.section) {
            heroStack
            textGroup
        }
        .padding(.top, 80)
    }

    /// 稿面 `V8wyl3`（Hero Stack）：沖印品照片壓在左上角＋出血重疊的通知預覽卡（`x:70,y:100`，
    /// 相對於照片卡自己的左上角，不隨畫面寬度置中——這是刻意的「出血」構圖，見 Notes `f6x5i`）。
    /// 照片本身純裝飾（`HeroPrintCard` 內部已 `.accessibilityHidden`，同 `ProfilePrintChip`
    /// 既有慣例）；通知預覽卡的文字**不**隱藏——那是「你會收到什麼通知」的實例，對 VoiceOver
    /// 使用者跟對看得到畫面的使用者一樣是有意義的資訊，不是純裝飾。
    private var heroStack: some View {
        let isAX = dynamicTypeSize.isAccessibilitySize
        return ZStack(alignment: .topLeading) {
            HeroPrintCard()
            NotificationPreviewCard(width: isAX ? 340 : 275)
                .offset(x: isAX ? 5 : 70, y: 100)
        }
        .frame(height: isAX ? 325 : 225, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 模擬器實測踩到：`body` 頂層是「`content`＋`Spacer`＋`footer`」的 `VStack`，`Spacer` 讓
    /// `content`／`footer` 的高度變成「彈性協商」的一部分——沒有 `.fixedSize(vertical: true)`
    /// 時，34pt 粗體標題在這個協商過程中第一輪拿到的高度提案只夠一行，SwiftUI 直接把換行後
    /// 的內容截斷成「開啟通知，不錯過家...」，不會有第二輪重新協商（同一份文字在沒有
    /// `Spacer` 兄弟的畫面——例如 `EULAConsentView`——不會踩到，因為那裡外層是 `ScrollView`
    /// 不做高度協商）。兩顆 `Text` 都補上，避免內文未來改長文案時同樣被截斷。
    private var textGroup: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("開啟通知，不錯過家人的每一刻")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "當家人新增照片、寫日記，或在你的動態下留言、按愛心時，我們會通知你——不會太吵，"
                    + "同一段時間的更新會合併成一則。"
            )
            .appFont(.body)
            .foregroundStyle(Color.lsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 稿面 `i4Llg`：CTA「開啟通知」是畫面唯一 `$accent`（`PrimaryButton`）；「稍後再說」借用
    /// 既有 `cmp/Button Text` 純文字次要動作語彙（同 `EULAConsentView.disagreeButton`），
    /// `minHeight: 48` 同該既有先例。CTA 按下後不論系統對話框結果為何（允許／拒絕）都關閉本頁
    /// ——票文範圍 2「註冊失敗記 log 不擋 UI」，這裡對應「不管結果都不卡住使用者」。
    private var footer: some View {
        VStack(spacing: AppSpacing.label) {
            PrimaryButton(icon: "bell", title: "開啟通知") {
                Task {
                    await pushNotificationStore.requestAuthorizationAndRegister()
                    onFinish()
                }
            }
            Button(action: onFinish) {
                Text("稍後再說")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            // LS-217 QA R1 FAIL（Linear comment `e4863482`）修正：`QADriver` 需要在真實 app 導覽
            // （非 `TapTargetGateHarness`）中辨識這個畫面出現，identifier 不影響 VoiceOver 朗讀
            // （見 `QAAccessibilityID` 檔頭），同該檔既有慣例不圍 `#if DEBUG`。
            .accessibilityIdentifier(QAAccessibilityID.pushPrepromptSkipButton)
        }
        .padding(.bottom, AppSpacing.block)
    }
}

/// 稿面 `zzXNT`（Hero Print）：沖印品照片＋對角兩顆角托（`.claude/skills/little-sprout-brand`
/// 「角托三段規則」——LS-177 起新畫的 Hero／Empty Print 用對角兩顆，不是既有 `PrintPhotoCard`
/// 的四顆），200×155（8pt 白邊＋184×139 相片），角托 26pt、corner-out 用既有
/// `AppSpacing.cornerOut`（5）——同 `ProfilePrintChip.corner` 的既有手法，只是這裡尺寸固定
/// 用稿面實測值（26／5），不是 `ProfilePrintChip` 那種依頭像 `size` 等比縮放的版本。
private struct HeroPrintCard: View {
    private let cornerSize: CGFloat = 26

    var body: some View {
        ZStack {
            Color.lsSurface2
            Image("HeroGrandma")
                .resizable()
                .scaledToFill()
        }
        .frame(width: 184, height: 139)
        .clipped()
        .padding(AppSpacing.printEdge)
        .background(Color.lsPrintPaper)
        .overlay(Rectangle().strokeBorder(Color.lsPaperEdge, lineWidth: 1))
        .shadow(color: Color.lsPaperShadow, radius: 6, x: 0, y: 3)
        .overlay(corner(.topLeading, alignment: .topLeading, out: -AppSpacing.cornerOut))
        .overlay(corner(.bottomTrailing, alignment: .bottomTrailing, out: AppSpacing.cornerOut))
        // 純裝飾照片（headline／body 已完整轉述「為什麼要通知」），同 `ProfilePrintChip`
        // 既有的 `.accessibilityHidden(true)` 慣例。
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

/// 稿面 `EnaX4`（Notification Preview）：模擬系統通知樣式的預覽卡——App icon（photo-stack
/// 定案資產）＋粗體 app 名稱＋一則範例通知文字（取自 Handoff Notes `xQXlf` 通知彙總文案矩陣的
/// media 範例「爸爸新增了 50 張照片」，與 LS-172／175 實際發送文案同一份範例，不會有「說一套
/// 做一套」的落差，見 Notes `yqtj8`）。
private struct NotificationPreviewCard: View {
    var width: CGFloat = 275

    var body: some View {
        HStack(spacing: AppSpacing.group) {
            Image("AppIconPhotoStackPreview")
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                // 純裝飾——app 名稱文字已傳達同一件事（「萌芽日記」），icon 圖像本身不需要
                // VoiceOver 額外朗讀。
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                Text("萌芽日記")
                    .appFont(.note, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                Text("爸爸新增了 50 張照片")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextPrimary)
            }
        }
        .padding(AppSpacing.insetCard)
        .frame(width: width, alignment: .leading)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                .strokeBorder(Color.lsBorder, lineWidth: 1)
        )
        .shadow(color: Color.lsPaperShadow, radius: 8, x: 0, y: 4)
    }
}

#if DEBUG
#Preview {
    PushPrepromptView(pushNotificationStore: .preview(), onFinish: {})
}

#Preview("深色") {
    PushPrepromptView(pushNotificationStore: .preview(), onFinish: {})
        .preferredColorScheme(.dark)
}
#endif

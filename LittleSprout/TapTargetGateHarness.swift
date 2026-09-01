#if DEBUG
import SwiftUI

/// LS-95：≥44pt 點擊目標機械 gate 的畫面掛載點。
///
/// XCUITest 啟動 app 時沒辦法「憑空」跳過登入／建立家庭流程直接開到某個 Feature 畫面——
/// `tap-target-check.sh`（透過 `TapTargetGateTests`）用 `LS_TAP_TARGET_GATE_SCREEN` 這個
/// launch environment 變數（值見 `TapTargetGateScreenName`）告訴 app「這次啟動請直接顯示這個
/// 畫面」，用既有 `#Preview` 已經在用的同一組 `.preview()` mock store 建構，不打真網路、不需要
/// `Config/Secrets.xcconfig`。
///
/// 只有 `TapTargetGateTests`／`TapTargetGateSelfTests` 會設這個環境變數，一般使用者啟動 app
/// 永遠讀不到、走 `LittleSproutApp.body` 原本的 `RootView` 路徑。整支 `#if DEBUG` 圍住——依賴
/// 的 `.preview()` 系列本身就只在 DEBUG 存在（見 `PreviewAuthService.swift` 等），Release
/// build 不會編到這支檔案，也不可能被誤觸發。
///
/// 新增受測畫面：`TapTargetGateScreenName` 加一個 case，這裡的 `hostView` 補對應分支。
enum TapTargetGateHarness {
    static var activeScreen: TapTargetGateScreenName? {
        ProcessInfo.processInfo.environment["LS_TAP_TARGET_GATE_SCREEN"]
            .flatMap(TapTargetGateScreenName.init(rawValue:))
    }

    @MainActor
    @ViewBuilder
    static func hostView(for screen: TapTargetGateScreenName) -> some View {
        switch screen {
        case .otpVerification:
            NavigationStack {
                // cooldownSeconds: 0：一開畫面 `canResend` 就是 true，重寄 Button 立刻顯示
                // （見 `OTPVerificationView.init` 文件註解），不必真的等 60 秒冷卻。
                OTPVerificationView(email: "grandma@example.com", authStore: .preview(), cooldownSeconds: 0) {}
            }
        case .settings:
            NavigationStack {
                // merge-review R1 M1(b)：「邀請家人」列只在 `familyStore.myFamily != nil` 才
                // 渲染（LS-107）——`.preview(withFamily:)` 同步餵一個家庭狀態，那顆列才會被量到
                // （見 `FamilyStore.seedMyFamilyForPreview`／`PreviewFamilyAPIClient.swift`）。
                SettingsView(
                    authStore: .preview(),
                    familyStore: .preview(withFamily: Family(
                        id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
                    )),
                    childrenStore: .preview()
                )
            }
        case .selfTestTooSmall:
            // `.frame()` 直接接在 `Button(_:action:)` 後面不可靠：純文字、預設樣式的按鈕，
            // accessibility／hit-test frame 實測仍貼著文字本身的天然大小，不會被外層 `.frame`
            // 撐大或縮小（LS-95 開發期間實測撞到——這正是本票要抓的那種「視覺／版面大小」跟
            // 「真正 hit-test 大小」對不上的落差）。改用 `.contentShape(Rectangle())` 明確把
            // hit-test 形狀鎖定成 `.frame` 給的矩形，樣本大小才會是可控、決定性的數字。
            Button(action: noop) {
                Text("小按鈕")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
        case .selfTestGood:
            Button(action: noop) {
                Text("好按鈕")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        case .selfTestPaddingOutsideButton:
            // 刻意重現 LS-17 QA1 的原始寫法（PR #148 R1 F1 修正前）：padding 掛在 Button 外層
            // 的 VStack，不是掛在 Button 的 label closure 裡再接 `.contentShape(Rectangle())`
            // ——視覺上按鈕四周看起來有一大圈空白，但那圈空白不參與 hit test，實際可點區域仍
            // 只有內容本身的大小（20×20，用同一招 `.contentShape` 鎖定成決定性數字）。
            VStack {
                Button(action: noop) {
                    Text("小按鈕")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
            }
            .padding(20)
        }
    }

    private static func noop() {}
}
#endif

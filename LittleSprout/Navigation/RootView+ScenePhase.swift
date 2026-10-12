import SwiftUI

extension RootView {
    /// `scenePhase` 變化處理（原在 `RootView.body` 的 `.onChange` 內，LS-502 R1b 抽出：`RootView.swift`
    /// 已在 SwiftLint `file_length` 400 行上限，只搬不改；唯一新增是 `sceneDidBecomeActive()` 一行）。
    func handleScenePhaseChange(_ phase: ScenePhase) {
        albumsStore.uploadQueueScenePhaseChanged(phase) // LS-397：進背景／回前景的上傳續傳
        if phase == .active {
            authStore.refreshSnapshot()
            authStore.sceneDidBecomeActive() // LS-502 R1b：熱回前景＋session 已過期 → 還原中，不閃登入頁
            // LS-217 票文範圍 2：「每次 App 進前景重讀狀態」——沒有登入者時沒有東西可重讀
            // （token 送出需要 `userID`），跳過。
            if let userID = authStore.session?.userID {
                Task { await pushNotificationStore.refreshOnForeground(userID: userID) }
            }
        }
    }
}

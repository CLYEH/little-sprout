import SwiftUI

extension RootView {
    /// `scenePhase` 變化處理（原在 `RootView.body` 的 `.onChange` 內，LS-502 R1b 抽出：`RootView.swift`
    /// 已在 SwiftLint `file_length` 400 行上限）。
    func handleScenePhaseChange(_ phase: ScenePhase) {
        albumsStore.uploadQueueScenePhaseChanged(phase) // LS-397：進背景／回前景的上傳續傳
        // LS-502 R1c：回前景一定先經 `.inactive`，body 此刻就依 scenePhase 重算路由；`.inactive` 與
        // `.active` 都要呼叫，否則「已登入但 session 已過期」的路由會先算成登入頁閃幾幀。
        // `refreshSnapshot()` 仍只在 `.active`（原行為；store 的 session 本來就由 `sessionUpdates`
        // 即時維護，快照只是補位，`.inactive` 不需要）。
        if phase == .background {
            authStore.sceneDidEnterBackground()
        } else {
            if phase == .active { authStore.refreshSnapshot() }
            authStore.sceneDidBecomeActive()
        }
        if phase == .active {
            // LS-217 票文範圍 2：「每次 App 進前景重讀狀態」——沒有登入者時沒有東西可重讀
            // （token 送出需要 `userID`），跳過。
            if let userID = authStore.session?.userID {
                Task { await pushNotificationStore.refreshOnForeground(userID: userID) }
            }
        }
    }
}

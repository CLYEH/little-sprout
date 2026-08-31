import Foundation

/// 加入路徑（LS-108：06 輸入邀請碼／06d 等待核准／owner 審核清單）用到的 `FamilyStore` 動作
/// ——拆成獨立檔案，理由同 `FamilyStoreInviteTests`／`SupabaseFamilyAPIClientJoinTests` 的拆檔
/// 說明：主檔 `FamilyStore.swift` 已經有三組既有狀態機，全部塞進同一個檔案會撞 SwiftLint
/// `file_length`（400 行上限）。狀態本身（`requestJoinState`／`myJoinRequest` 等）仍宣告在主檔
/// （Swift extension 不能新增 stored property），這裡只放操作它們的方法。
extension FamilyStore {
    /// 送出加入申請。成功且結果是 `.joined`（家庭關閉審核）時直接重新查詢 `myFamily`，讓
    /// root routing 自動離開三岔路——跟 `createFamily` 成功後的既有慣例一致（見該方法文件），
    /// 不需要呼叫端另外導頁。`.pending` 由呼叫端（`JoinCodeView`）自己導去 06d。
    @discardableResult
    func requestJoin(code: String) async -> JoinRequestOutcome? {
        guard !requestJoinState.isSubmitting else { return nil }
        requestJoinState = .submitting
        do {
            let outcome = try await apiClient.requestJoin(code: code)
            requestJoinState = .success
            if case .joined = outcome {
                await refreshMyFamily()
            }
            return outcome
        } catch {
            requestJoinState = .failure(AppError.map(error))
            return nil
        }
    }

    /// 重新導航回 06（例如撤回申請後想再試一次）時，把上一次失敗的殘影清掉——理由同
    /// `resetCreateFamilyState`。
    func resetRequestJoinState() {
        guard case .failure = requestJoinState else { return }
        requestJoinState = .idle
    }

    /// 06d 輪詢用：查詢自己目前最相關的一筆申請。輪詢失敗（多半是網路）時刻意不覆寫
    /// `myJoinRequest`——保留使用者已經看到的最後已知狀態，下一次輪詢再試，不要讓暫時的網路
    /// 抖動把「還在等待」畫面閃成一片空白。
    @discardableResult
    func refreshMyJoinRequest() async -> MyJoinRequest? {
        do {
            myJoinRequest = try await apiClient.myJoinRequest()
        } catch {
            // 靜默重試：見上方文件註解。
        }
        return myJoinRequest
    }

    /// 撤回自己送出的申請。
    @discardableResult
    func withdrawJoinRequest(requestID: UUID) async -> Bool {
        guard !withdrawJoinState.isSubmitting else { return false }
        withdrawJoinState = .submitting
        do {
            try await apiClient.withdrawJoin(requestID: requestID)
            withdrawJoinState = .success
            return true
        } catch {
            withdrawJoinState = .failure(AppError.map(error))
            return false
        }
    }

    /// Owner 審核清單：查詢自己是 owner 的所有家庭目前待審的申請。
    @discardableResult
    func refreshPendingJoinRequests() async -> [PendingJoinRequest] {
        guard !listJoinRequestsState.isSubmitting else { return pendingJoinRequests }
        listJoinRequestsState = .submitting
        do {
            pendingJoinRequests = try await apiClient.listJoinRequests()
            listJoinRequestsState = .success
        } catch {
            listJoinRequestsState = .failure(AppError.map(error))
        }
        return pendingJoinRequests
    }

    /// 這筆申請目前是否有核准／拒絕動作正在進行中——每筆申請各自的旗標，核准 A 不擋拒絕 B
    /// （不像上面幾個共用單一狀態機的動作：owner 審核清單一次可能有好幾筆，逐列各自獨立才
    /// 合理）。
    func isProcessingJoinRequest(_ requestID: UUID) -> Bool {
        processingJoinRequestIDs.contains(requestID)
    }

    /// 核准一筆待審申請；成功就把它從本地清單移除（不必整份重查一次）。
    @discardableResult
    func approveJoinRequest(_ requestID: UUID) async -> Bool {
        await performJoinRequestAction(requestID) { [apiClient] in
            try await apiClient.approveJoin(requestID: requestID)
        }
    }

    /// 拒絕一筆待審申請；成功就把它從本地清單移除。
    @discardableResult
    func rejectJoinRequest(_ requestID: UUID) async -> Bool {
        await performJoinRequestAction(requestID) { [apiClient] in
            try await apiClient.rejectJoin(requestID: requestID)
        }
    }

    func clearJoinRequestActionError() {
        joinRequestActionError = nil
    }

    /// 換使用者／登出時歸零——`FamilyStore.reset()`（主檔）呼叫這支，理由同其餘狀態：這個
    /// 型別隨 app 存活，不會自動清空。
    func resetJoinRequestsState() {
        requestJoinState = .idle
        myJoinRequest = nil
        withdrawJoinState = .idle
        listJoinRequestsState = .idle
        pendingJoinRequests = []
        joinRequestActionError = nil
        processingJoinRequestIDs = []
    }

    /// 核准／拒絕共用的骨架：per-request-id 旗標擋同一筆的重複點擊、成功後從本地清單移除、
    /// 失敗寫進 `joinRequestActionError`。兩支呼叫共用同一組 guard／清單維護邏輯，只有真正打
    /// 哪支 RPC 不同，這裡收斂成一支私有函式避免重複。
    private func performJoinRequestAction(_ requestID: UUID, action: @escaping () async throws -> Void) async -> Bool {
        guard !isProcessingJoinRequest(requestID) else { return false }
        processingJoinRequestIDs.insert(requestID)
        defer { processingJoinRequestIDs.remove(requestID) }
        do {
            try await action()
            pendingJoinRequests.removeAll { $0.requestID == requestID }
            return true
        } catch {
            joinRequestActionError = AppError.map(error)
            return false
        }
    }
}

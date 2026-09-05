import Foundation

/// LS-192：02 顯示名稱與頭像編輯——拆成獨立檔案的理由同 `FamilyStore+JoinRequests.swift`
/// 檔頭註解（`FamilyStore.swift` 逼近 SwiftLint `file_length` 上限）。狀態宣告在
/// `FamilyStore.swift`（Swift extension 不能加 stored property）。
extension FamilyStore {
    #if DEBUG
    /// 只給 SwiftUI `#Preview`／`TapTargetGateHarness` 用：同步把 `myProfile` 設成給定值，
    /// 不需要真的走一次 async `refreshProfile()`（同 `seedMyFamilyForPreview` 的既有作法）。
    func seedProfileForPreview(_ profile: Profile) {
        myProfile = profile
    }
    #endif

    /// 02 進場查詢自己的 profile；成功後順便重簽頭像 URL（跟 03 家庭成員清單共用同一份
    /// `avatarSignedURLs` 快取，見該屬性文件註解）。
    ///
    /// R2（merge-review R1 m7，PLAUSIBLE）：await 前後核對 `ownerUserID`，同
    /// `FamilyStore.refreshQuota()` 既有理由——這段 RTT 期間若 `syncOwner()` 把 store 換成
    /// 別的使用者（切帳號，或退出家庭後 `reset()`），這裡查到的結果已經過期，直接丟棄、
    /// 不覆寫，避免上一個使用者的顯示名稱寫進下一個使用者的 `myProfile`。
    @discardableResult
    func refreshProfile() async -> Profile? {
        guard !profileState.isSubmitting else { return myProfile }
        guard let requestOwnerID = ownerUserID else { return myProfile }
        profileState = .submitting
        do {
            let result = try await apiClient.fetchMyProfile()
            guard ownerUserID == requestOwnerID else {
                profileState = .idle
                return myProfile
            }
            myProfile = result
            profileState = .success
            await refreshAvatarSignedURLs()
        } catch {
            guard ownerUserID == requestOwnerID else {
                profileState = .idle
                return myProfile
            }
            profileState = .failure(AppError.map(error))
        }
        return myProfile
    }

    /// 儲存顯示名稱；長度／空白規則由呼叫端（`ProfileEditView`）先驗過，這裡直接送出。
    /// 成功後就地更新 `myProfile`，設定頁署名（`ProfileSummaryRow`）下一次重繪立刻反映新名字
    /// ——兩者讀的是同一份 `FamilyStore.myProfile`，不需要額外的通知機制。
    @discardableResult
    func updateDisplayName(_ name: String) async -> Bool {
        guard !updateDisplayNameState.isSubmitting else { return false }
        updateDisplayNameState = .submitting
        do {
            myProfile = try await apiClient.updateDisplayName(name)
            updateDisplayNameState = .success
            return true
        } catch {
            updateDisplayNameState = .failure(AppError.map(error))
            return false
        }
    }

    func resetUpdateDisplayNameState() {
        guard case .failure = updateDisplayNameState else { return }
        updateDisplayNameState = .idle
    }

    /// 上傳新頭像＋寫入 `profiles.avatar_url`——重用 LS-169 服務（見
    /// `ChildAvatarUploadService.uploadProfileAvatar` 文件註解）。`familyID` 由呼叫端
    /// （`ProfileEditView`）帶進來：`SettingsView` 只在 `myFamily != nil` 才進得去（見該檔
    /// 文件註解），理論上一定有值，呼叫端仍應自行確認。
    @discardableResult
    func updateAvatar(familyID: UUID, imageData: Data) async -> Bool {
        guard !updateAvatarState.isSubmitting, let userID = ownerUserID else { return false }
        updateAvatarState = .submitting
        do {
            let path = try await avatarUploadService.uploadProfileAvatar(
                familyID: familyID, userID: userID, imageData: imageData
            )
            myProfile = try await apiClient.updateAvatarPath(path)
            // LS-174 同型 cache-bust：固定路徑＋upsert 換照片，字面路徑不變但內容變了，見
            // `avatarCacheBust` 文件註解。
            avatarCacheBust[path] = Date().timeIntervalSince1970
            updateAvatarState = .success
            await refreshAvatarSignedURLs()
            return true
        } catch {
            updateAvatarState = .failure(AppError.map(error))
            return false
        }
    }

    func resetUpdateAvatarState() {
        guard case .failure = updateAvatarState else { return }
        updateAvatarState = .idle
    }

    /// 把 `Profile.avatarURL`／`FamilyMember.avatarURL` 這種原始欄位值換成可以直接丟給
    /// `AsyncImage` 的 URL——OAuth 提供的公開網址（`ProfileAvatarPath.isStoragePath` 為
    /// false）直接回傳；自行上傳的 Storage 路徑查 `avatarSignedURLs`（還沒簽回來時回 nil，
    /// 呼叫端退回縮寫，同 `ChildrenStore.avatarURL(for:)` 的既有慣例），並疊加 cache-bust
    /// 查詢參數。
    func avatarDisplayURL(rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        guard ProfileAvatarPath.isStoragePath(rawValue) else { return URL(string: rawValue) }
        guard let signed = avatarSignedURLs[rawValue] else { return nil }
        guard let bust = avatarCacheBust[rawValue],
              var components = URLComponents(url: signed, resolvingAgainstBaseURL: false) else {
            return signed
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "lsv", value: String(bust))]
        return components.url ?? signed
    }

    /// 批次重簽：自己 `myProfile.avatarURL` ＋ `members` 裡每個人的 `avatarURL`，僅限 Storage
    /// 路徑（OAuth 網址不需要簽名）。世代守門同 `ChildrenStore.avatarSignedURLsGeneration`：
    /// `refreshMembers()`／`refreshProfile()` 重疊呼叫時，只有「發起時仍是最新一次」的回應
    /// 才寫入 `avatarSignedURLs`，較舊的回應晚到會被丟棄。
    func refreshAvatarSignedURLs() async {
        let paths = Set(
            ([myProfile?.avatarURL].compactMap { $0 }) + members.compactMap(\.avatarURL)
        ).filter(ProfileAvatarPath.isStoragePath)
        guard !paths.isEmpty else { return }
        avatarSignedURLsGeneration += 1
        let generation = avatarSignedURLsGeneration
        let signed = (try? await apiClient.signedAvatarURLs(forPaths: Array(paths))) ?? [:]
        guard generation == avatarSignedURLsGeneration else { return }
        avatarSignedURLs.merge(signed) { _, new in new }
    }
}

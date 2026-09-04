import Foundation
import Observation

/// `ChildrenStore` 各非同步動作共用的狀態機，同 `FamilyStore.FamilyOperationState`（LS-107）
/// 的角色：`idle`→尚未開始、`submitting`→呼叫中、`success`→上一次呼叫成功、
/// `failure`→上一次呼叫失敗並帶對映後的 `AppError`。
enum ChildOperationState: Equatable {
    case idle
    case submitting
    case success
    case failure(AppError)

    var isSubmitting: Bool { self == .submitting }
}

/// 孩子檔案（多寶貝，LS-47／LS-66／LS-113／LS-169）的 `@Observable` 狀態管理，把
/// `ChildAPIClient` 包成畫面能直接讀狀態驅動重繪的 store（同 `FamilyStore` 之於
/// `FamilyAPIClient` 的角色）。
///
/// 刻意不像 `FamilyStore` 的 `createInvite`／`refreshLatestInvite` 那樣互相檢查對方的
/// `isSubmitting`：那條互斥規則解的是「同一個畫面兩個不同動作可能併發觸發」的既定 race
/// （R2 N1），本 store 的建立／編輯／刪除三個動作分別只會在各自獨立的畫面被觸發（08／09b／
/// 09c 一次只會有一個在前景），不存在同一時間兩個動作互相搶寫同一份狀態的情境，每個動作
/// 各自的 in-flight guard（擋自己重入）已足夠。
@MainActor
@Observable
final class ChildrenStore {
    private let apiClient: ChildAPIClient
    private let avatarUploadService: ChildAvatarUploadService

    private(set) var children: [Child] = []
    private(set) var listState: ChildOperationState = .idle
    private(set) var createState: ChildOperationState = .idle
    private(set) var updateState: ChildOperationState = .idle
    private(set) var deleteState: ChildOperationState = .idle
    /// 呼叫者在目前家庭的角色——決定「新增」「編輯」「刪除」「還原」四個入口的可見度
    /// （LS-113 票文 Scope：owner＋member 可編輯，刪除／還原僅 owner）。
    private(set) var myRole: FamilyRole?
    /// `Child.avatarURL`（Storage 路徑）→ 短效簽名 URL，`refresh`／`reloadChildrenList` 後
    /// 批次重簽（LS-169）。沒有 `avatarURL` 的孩子、或簽名剛好失敗的路徑不會出現在這裡——
    /// 呼叫端用 `avatarURL(for:)` 取，缺鍵時自然退回縮寫（同 `docs/API.md` §6「`thumb_path`
    /// 為 NULL 時退回原圖」的既有慣例：這裡沒有退回層，缺鍵就是顯示縮寫）。
    private(set) var avatarSignedURLs: [String: URL] = [:]

    private var familyID: UUID?
    /// 建檔流程「先 `create_child` 取 id 再上傳＋`update_child`」（票文 Scope 1）留下的中繼
    /// 狀態：`create_child` 已成功、但上傳頭像／`update_child` 那一步失敗時記下這個 id，
    /// 讓使用者在同一個畫面重試「建立寶貝檔案」時不會又呼叫一次 `create_child`（否則會建出
    /// 兩筆同名孩子——`create_child` 沒有冪等鍵，重試安全性要靠呼叫端自己不重送）。只有
    /// `resetCreateState()`（畫面 `onAppear` 呼叫，代表「重新進入這個畫面」）會清掉它，
    /// 同一個畫面實例內的重試會沿用同一個 id。
    private var pendingCreateChildID: UUID?

    init(apiClient: ChildAPIClient, avatarUploadService: ChildAvatarUploadService) {
        self.apiClient = apiClient
        self.avatarUploadService = avatarUploadService
    }

    /// 在案（未軟刪）的孩子——09 列表／10 切換器只列這些。
    var activeChildren: [Child] { children.filter { !$0.isDeleted } }

    /// 已軟刪（30 天內可能還原）的孩子——09 的「已移除的寶貝」揭露列、10 下拉選單的還原區段。
    var removedChildren: [Child] { children.filter(\.isDeleted) }

    var isOwner: Bool { myRole == .owner }

    /// owner／member 皆可新增／編輯孩子檔案（LS-66）；viewer 不行。
    var canManageChildren: Bool { myRole == .owner || myRole == .member }

    /// 這個孩子的頭像簽名 URL；沒有 `avatarURL`、或簽名還沒回來／失敗時回傳 nil——呼叫端
    /// （`ChildAvatarView`）用 nil 顯示縮寫。
    func avatarURL(for child: Child) -> URL? {
        guard let path = child.avatarURL else { return nil }
        return avatarSignedURLs[path]
    }

    /// 查詢一個家庭的孩子清單＋呼叫者角色；09／10 畫面 `onAppear` 呼叫。
    @discardableResult
    func refresh(familyID: UUID) async -> [Child] {
        guard !listState.isSubmitting else { return children }
        self.familyID = familyID
        listState = .submitting
        do {
            async let childrenTask = apiClient.listChildren(familyID: familyID)
            async let roleTask = apiClient.fetchMyRole(familyID: familyID)
            let (fetchedChildren, role) = try await (childrenTask, roleTask)
            children = fetchedChildren
            myRole = role
            listState = .success
        } catch {
            listState = .failure(AppError.map(error))
        }
        await refreshAvatarSignedURLs()
        return children
    }

    /// 建立孩子檔案；`avatarImageData` 非 nil 時，`create_child` 成功後接著上傳頭像＋
    /// `update_child`（票文 Scope 1：建檔流程先 `create_child` 取 id 再上傳＋`update_child`）。
    /// **失敗回滾語意**：頭像上傳／`update_child` 這一步失敗時，`create_child` 已成功的孩子
    /// **不會**被撤銷（沒有硬刪路徑可用，見 `docs/API.md` §3 `children`）——保留無圖，回傳
    /// `false` 讓呼叫端顯示既有錯誤文案，`pendingCreateChildID` 記住這個 id 供重試沿用。
    @discardableResult
    func createChild(name: String, birthday: Date, avatarImageData: Data? = nil) async -> Bool {
        guard !createState.isSubmitting else { return false }
        guard let familyID else {
            createState = .failure(.rejected(message: "沒有家庭可以新增寶貝", code: nil))
            return false
        }
        createState = .submitting
        do {
            let childID: UUID
            if let pendingCreateChildID {
                childID = pendingCreateChildID
            } else {
                childID = try await apiClient.createChild(
                    familyID: familyID, name: name, birthday: birthday, avatarURL: nil
                )
                pendingCreateChildID = childID
            }
            if let avatarImageData {
                let path = try await avatarUploadService.uploadAvatar(
                    familyID: familyID, childID: childID, imageData: avatarImageData
                )
                try await apiClient.updateChild(childID: childID, name: name, birthday: birthday, avatarURL: path)
            }
            pendingCreateChildID = nil
            createState = .success
            await reloadChildrenList()
            return true
        } catch {
            createState = .failure(AppError.map(error))
            await reloadChildrenList()
            return false
        }
    }

    func resetCreateState() {
        pendingCreateChildID = nil
        guard case .failure = createState else { return }
        createState = .idle
    }

    /// 編輯既有孩子檔案（PUT 語意整組替換）；`newAvatarImageData` 非 nil 時先上傳新頭像，
    /// 成功才帶新路徑呼叫 `update_child`——上傳失敗就整段不呼叫 `update_child`，保留原有的
    /// `currentAvatarURL` 不變（同「上傳失敗保留無圖」的精神：編輯情境下是保留原圖）。
    @discardableResult
    func updateChild(
        childID: UUID, name: String, birthday: Date, currentAvatarURL: String?, newAvatarImageData: Data? = nil
    ) async -> Bool {
        guard !updateState.isSubmitting else { return false }
        updateState = .submitting
        do {
            var avatarURL = currentAvatarURL
            if let newAvatarImageData {
                guard let familyID else {
                    throw AppError.rejected(message: "沒有家庭可以更新寶貝", code: nil)
                }
                avatarURL = try await avatarUploadService.uploadAvatar(
                    familyID: familyID, childID: childID, imageData: newAvatarImageData
                )
            }
            try await apiClient.updateChild(childID: childID, name: name, birthday: birthday, avatarURL: avatarURL)
            updateState = .success
            await reloadChildrenList()
            return true
        } catch {
            updateState = .failure(AppError.map(error))
            return false
        }
    }

    func resetUpdateState() {
        guard case .failure = updateState else { return }
        updateState = .idle
    }

    /// 軟刪（`deleted: true`，僅 owner）／還原（`deleted: false`，僅 owner，30 天內）；
    /// 成功後重新整理清單。
    @discardableResult
    func setChildDeleted(childID: UUID, deleted: Bool) async -> Bool {
        guard !deleteState.isSubmitting else { return false }
        deleteState = .submitting
        do {
            try await apiClient.setChildDeleted(childID: childID, deleted: deleted)
            deleteState = .success
            await reloadChildrenList()
            return true
        } catch {
            deleteState = .failure(AppError.map(error))
            return false
        }
    }

    func resetDeleteState() {
        guard case .failure = deleteState else { return }
        deleteState = .idle
    }

    /// 登出時歸零——同 `FamilyStore.reset()` 的角色，避免下一位登入者沿用上一位的孩子清單。
    func reset() {
        familyID = nil
        children = []
        myRole = nil
        avatarSignedURLs = [:]
        pendingCreateChildID = nil
        listState = .idle
        createState = .idle
        updateState = .idle
        deleteState = .idle
    }

    private func reloadChildrenList() async {
        guard let familyID else { return }
        if let fetched = try? await apiClient.listChildren(familyID: familyID) {
            children = fetched
        }
        await refreshAvatarSignedURLs()
    }

    /// 批次重簽目前 `children` 裡所有非 nil 的 `avatarURL`——整批用同一份字典取代舊值（不是
    /// 逐一合併）：孩子清單本身也可能變動（軟刪／還原／換照片後路徑不變但內容變了，簽名 URL
    /// 需要跟著換），整批換掉比合併更不容易留下對不上清單的殘影。簽名本身失敗（例如網路
    /// 問題）不當成整體失敗，`avatarSignedURLs` 保持舊值——同一輪 `refresh` 重試會再簽一次。
    private func refreshAvatarSignedURLs() async {
        let paths = children.compactMap(\.avatarURL)
        guard !paths.isEmpty else {
            avatarSignedURLs = [:]
            return
        }
        if let signed = try? await apiClient.signedAvatarURLs(forPaths: paths) {
            avatarSignedURLs = signed
        }
    }
}

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

/// 孩子檔案（多寶貝，LS-47／LS-66／LS-113）的 `@Observable` 狀態管理，把 `ChildAPIClient`
/// 包成畫面能直接讀狀態驅動重繪的 store（同 `FamilyStore` 之於 `FamilyAPIClient` 的角色）。
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

    private(set) var children: [Child] = []
    private(set) var listState: ChildOperationState = .idle
    private(set) var createState: ChildOperationState = .idle
    private(set) var updateState: ChildOperationState = .idle
    private(set) var deleteState: ChildOperationState = .idle
    /// 呼叫者在目前家庭的角色——決定「新增」「編輯」「刪除」「還原」四個入口的可見度
    /// （LS-113 票文 Scope：owner＋member 可編輯，刪除／還原僅 owner）。
    private(set) var myRole: FamilyRole?

    private var familyID: UUID?

    init(apiClient: ChildAPIClient) {
        self.apiClient = apiClient
    }

    /// 在案（未軟刪）的孩子——09 列表／10 切換器只列這些。
    var activeChildren: [Child] { children.filter { !$0.isDeleted } }

    /// 已軟刪（30 天內可能還原）的孩子——09 的「已移除的寶貝」揭露列、10 下拉選單的還原區段。
    var removedChildren: [Child] { children.filter(\.isDeleted) }

    var isOwner: Bool { myRole == .owner }

    /// owner／member 皆可新增／編輯孩子檔案（LS-66）；viewer 不行。
    var canManageChildren: Bool { myRole == .owner || myRole == .member }

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
        return children
    }

    /// 建立孩子檔案；成功後重新整理清單，讓 09 立刻看到新的一筆。
    @discardableResult
    func createChild(name: String, birthday: Date, avatarURL: String? = nil) async -> Bool {
        guard !createState.isSubmitting else { return false }
        guard let familyID else {
            createState = .failure(.rejected(message: "沒有家庭可以新增寶貝", code: nil))
            return false
        }
        createState = .submitting
        do {
            _ = try await apiClient.createChild(
                familyID: familyID, name: name, birthday: birthday, avatarURL: avatarURL
            )
            createState = .success
            await reloadChildrenList()
            return true
        } catch {
            createState = .failure(AppError.map(error))
            return false
        }
    }

    func resetCreateState() {
        guard case .failure = createState else { return }
        createState = .idle
    }

    /// 編輯既有孩子檔案（PUT 語意整組替換）；成功後重新整理清單。
    @discardableResult
    func updateChild(childID: UUID, name: String, birthday: Date, avatarURL: String?) async -> Bool {
        guard !updateState.isSubmitting else { return false }
        updateState = .submitting
        do {
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
    }
}

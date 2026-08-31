import Foundation

/// 孩子檔案（多寶貝，LS-47／LS-66）的型別化 client 介面。
///
/// 方法 ↔ RPC／資料表對照（供 `docs/API.md` 對帳）：
///   - `listChildren`     → RPC `list_children(p_family_id)`
///   - `createChild`      → RPC `create_child(p_family_id, p_name, p_birthday, p_avatar_url)`
///   - `updateChild`      → RPC `update_child(p_child_id, p_name, p_birthday, p_avatar_url)`
///   - `setChildDeleted`  → RPC `set_child_deleted(p_child_id, p_deleted)`
///   - `fetchMyRole`      → SELECT `public.family_members`（`role` 欄，篩 `user_id = auth.uid()`；
///                          09／10 畫面要依 owner／member／viewer 決定「新增」「編輯」「刪除」
///                          「還原」四個入口的可見度，見 LS-113 票文 Scope）
///
/// 錯誤一律映射為 `AppError`（見該檔），不直接往外拋 PostgREST 的 error 型別。
protocol ChildAPIClient: Sendable {
    /// 列出一個家庭的孩子檔案（依 birthday 排序）。回傳全部列，不分角色、不分軟刪與否
    /// （LS-66 R1 I3/I4）——呼叫端自行依 `deletedAt` 分流「在案」與「已移除」。
    func listChildren(familyID: UUID) async throws -> [Child]

    /// 建立孩子檔案；該家庭 owner／member 皆可呼叫。回傳新建列的 id。
    func createChild(familyID: UUID, name: String, birthday: Date, avatarURL: String?) async throws -> UUID

    /// PUT 語意整組替換 `name`／`birthday`／`avatarURL`；仍是該家庭 owner／member 的成員才能成功。
    func updateChild(childID: UUID, name: String, birthday: Date, avatarURL: String?) async throws

    /// 軟刪（`deleted: true`）／還原（`deleted: false`）；僅該家庭 owner 能成功。
    func setChildDeleted(childID: UUID, deleted: Bool) async throws

    /// 呼叫者在這個家庭的角色；從未加入過（理論上不會發生在已進入本畫面的情境）回傳 nil。
    func fetchMyRole(familyID: UUID) async throws -> FamilyRole?
}

import Foundation
import Supabase

/// LS-192：03 家庭成員清單／移除／轉移 Owner ＋ 02 個人 profile 讀寫——拆成獨立檔案，理由同
/// `FamilyStore+Members.swift`／`FamilyStore+Profile.swift` 檔頭註解（`SupabaseFamilyAPIClient.swift`
/// 主檔逼近 SwiftLint `file_length`／`type_body_length` 上限）。`client`／`signedURLExpirySeconds`／
/// `avatarBucket` 不是 `private`，見主檔文件註解。
extension SupabaseFamilyAPIClient {
    /// LS-192：見協定文件註解——直接 SELECT join，不需要 RPC。排序在記憶體裡做（不是
    /// `.order("role", …)`）：`family_role` 三個字面值的字母序（member < owner < viewer）
    /// 不是想要的「owner 優先」順序，見 `FamilyRole.sortRank` 文件註解。
    func listMembers(familyID: UUID) async throws -> [FamilyMember] {
        do {
            let response: PostgrestResponse<[FamilyMember]> = try await client
                .from("family_members")
                .select("user_id, role, profiles(display_name, avatar_url)")
                .eq("family_id", value: familyID)
                .execute()
            return response.value.sorted { lhs, rhs in
                if lhs.role.sortRank != rhs.role.sortRank { return lhs.role.sortRank < rhs.role.sortRank }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        } catch {
            throw AppError.map(error)
        }
    }

    /// 同 `revokeInvite`／`requireUpdatedRow` 的既有理由：`family_members_delete` 的 RLS 是
    /// USING 過濾，呼叫者不符合條件時 DELETE 合法執行但匹配 0 列，PostgREST 回 200 + `[]`，
    /// SDK 不會 throw——這裡明確把「0 列受影響」轉成錯誤，不讓 UI 誤以為移除／退出成功了。
    /// （唯一 owner 且家庭還有其他成員的情況不會走到這裡：DB trigger 會先 raise `LS057`，
    /// 直接落進下面的 catch。）
    func removeMember(familyID: UUID, userID: UUID) async throws {
        do {
            let response: PostgrestResponse<[FamilyMemberIdentityRow]> = try await client
                .from("family_members")
                .delete()
                .eq("family_id", value: familyID)
                .eq("user_id", value: userID)
                .select("user_id")
                .execute()
            guard !response.value.isEmpty else {
                throw AppError.rejected(message: "沒有權限移除這位成員，或這位成員已經不在家庭裡", code: "no_rows_deleted")
            }
        } catch {
            throw AppError.map(error)
        }
    }

    func transferOwnership(familyID: UUID, toUserID: UUID) async throws -> TransferOwnershipResult {
        do {
            let params = TransferOwnershipParams(familyID: familyID, toUserID: toUserID)
            let response: PostgrestResponse<TransferOwnershipResult> = try await client
                .rpc("transfer_ownership", params: params)
                .single()
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    /// LS-192：`profiles_select` 的 `peer_profile_ids()` 一定放行自己，理論上不會是 0 列——
    /// 仍用 `.single()`（不是 `.first`）：0 列在這裡代表資料不一致（`private.handle_new_
    /// auth_user()` trigger 沒有正常建列，見 docs/API.md §3），fail loud 比靜默回一個假的
    /// 「新成員」空殼更安全。
    func fetchMyProfile() async throws -> Profile {
        do {
            let session = try await client.auth.session
            let response: PostgrestResponse<Profile> = try await client
                .from("profiles")
                .select()
                .eq("id", value: session.user.id)
                .single()
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func updateDisplayName(_ name: String) async throws -> Profile {
        do {
            let session = try await client.auth.session
            let response: PostgrestResponse<Profile> = try await client
                .from("profiles")
                .update(["display_name": name])
                .eq("id", value: session.user.id)
                .select()
                .single()
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func updateAvatarPath(_ path: String) async throws -> Profile {
        do {
            let session = try await client.auth.session
            let response: PostgrestResponse<Profile> = try await client
                .from("profiles")
                .update(["avatar_url": path])
                .eq("id", value: session.user.id)
                .select()
                .single()
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    /// 同 `SupabaseChildAPIClient.signedAvatarURLs` 的既有實作（單一路徑簽名失敗略過、不讓
    /// 整批失敗）——這裡不重用那個型別，理由見該檔文件註解「兩邊剛好都簽同一個 bucket 只是
    /// 巧合，不是共用邊界」，同樣適用在這裡。
    func signedAvatarURLs(forPaths paths: [String]) async throws -> [String: URL] {
        guard !paths.isEmpty else { return [:] }
        do {
            let results = try await client.storage.from(Self.avatarBucket).createSignedURLs(
                paths: paths, expiresIn: Self.signedURLExpirySeconds
            )
            var urlsByPath: [String: URL] = [:]
            for result in results {
                switch result {
                case .success(let path, let signedURL):
                    urlsByPath[path] = signedURL
                case .failure:
                    continue
                }
            }
            return urlsByPath
        } catch {
            throw AppError.map(error)
        }
    }
}

// MARK: - Wire payloads

private struct TransferOwnershipParams: Encodable {
    let familyID: UUID
    let toUserID: UUID

    enum CodingKeys: String, CodingKey {
        case familyID = "p_family_id"
        case toUserID = "p_to_user_id"
    }
}

/// `removeMember` 的 DELETE `.select("user_id")` 回應——只用來判斷「有沒有列被刪掉」，
/// 不需要完整的 `FamilyMember`（那需要 join `profiles`，DELETE 回應不會帶）。
private struct FamilyMemberIdentityRow: Decodable {
    let userID: UUID

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}
